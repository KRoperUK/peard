// Package profile lets a signed-in user set the name other people see, and
// delete their own account outright.
//
//	GET    /api/peard/profile                    -> { id, display_name, email }
//	POST   /api/peard/profile { display_name }   -> { id, display_name, email }
//	DELETE /api/peard/account                    -> { ok }
//
// Names matter more than they look: `GET /api/peard/connections` resolves every
// member to a display name, and with none set it falls back to the local part of
// their email — so a group of four reads as a list of email prefixes. Nothing in
// the app could set one before this route existed.
//
// This is a route rather than a PATCH against the `users` collection because the
// collection's UpdateRule cannot be narrowed to a single field: whatever rule
// admitted `display_name` would also admit `email`, `password` and
// `emailVisibility`. Here exactly one field is writable, and it is validated.
package profile

import (
	"net/http"
	"strings"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// maxDisplayNameLength matches the users.display_name column (80 characters).
const maxDisplayNameLength = 80

// Register binds the profile routes and keeps `name` in step with
// `display_name`.
func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		g := se.Router.Group("/api/peard/profile")
		g.GET("", readHandler(app)).Bind(apis.RequireAuth())
		g.POST("", writeHandler(app)).Bind(apis.RequireAuth())

		se.Router.DELETE("/api/peard/account", deleteAccountHandler(app)).Bind(apis.RequireAuth())
		return se.Next()
	})
	registerNameMirror(app)
}

// registerNameMirror fills the stock `name` field from `display_name` whenever
// it would otherwise be blank.
//
// Pear'd never writes `name`: the app's own field is `display_name`, added by
// the init migration because the default one carries no meaning here. But
// PocketBase's admin console labels a relation with `name`, so every
// pair_members row, every post and every reaction rendered as a bare record id
// — the console was unusable for exactly the thing it is good at, which is
// following relations while working out what happened.
//
// Only when blank. Somebody who sets `name` in the console meant to, and having
// it silently overwritten on the next profile save would be worse than the
// problem this fixes.
//
// A hook rather than a computed column because there is nowhere to compute it:
// the console reads the stored row.
func registerNameMirror(app core.App) {
	mirror := func(e *core.RecordEvent) error {
		if strings.TrimSpace(e.Record.GetString("name")) == "" {
			if display := strings.TrimSpace(e.Record.GetString("display_name")); display != "" {
				e.Record.Set("name", display)
			}
		}
		return e.Next()
	}
	app.OnRecordCreate("users").BindFunc(mirror)
	app.OnRecordUpdate("users").BindFunc(mirror)
}

// deleteAccountHandler erases the caller's account outright.
//
// Deleting the `users` record is the whole act: every relation that points at
// a user — pair_members, posts (a person's moments in every connection),
// reactions, pair_invites, devices, widget_tokens — was declared with
// CascadeDelete: true (see 1785110400_peard_init.go), and losing the last
// member of a connection already deletes that connection's own posts,
// reactions and custom moments through registerLifecycle in
// internal/pairs/lifecycle.go, whose own doc comment names this exact route
// as the reason that hook lives at the model layer rather than behind
// /pairs/leave. A connection that still has other members keeps its shared
// history; only the deleted account's own moments in it go.
func deleteAccountHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		user, err := app.FindRecordById("users", e.Auth.Id)
		if err != nil {
			return e.NotFoundError("user not found", err)
		}
		if err := app.Delete(user); err != nil {
			return e.InternalServerError("failed to delete your account", err)
		}
		return e.JSON(http.StatusOK, map[string]any{"ok": true})
	}
}

func readHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		user, err := app.FindRecordById("users", e.Auth.Id)
		if err != nil {
			return e.NotFoundError("user not found", err)
		}
		return e.JSON(http.StatusOK, present(user))
	}
}

func writeHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			DisplayName string `json:"display_name" form:"display_name"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}

		// An empty name is a deliberate reset rather than an error: it puts the
		// caller back on the email-local-part fallback.
		name := sanitise(body.DisplayName)

		user, err := app.FindRecordById("users", e.Auth.Id)
		if err != nil {
			return e.NotFoundError("user not found", err)
		}
		user.Set("display_name", name)
		if err := app.Save(user); err != nil {
			return e.InternalServerError("failed to save your name", err)
		}
		return e.JSON(http.StatusOK, present(user))
	}
}

// sanitise trims, collapses runs of whitespace, strips control characters and
// truncates by rune. Newlines and tabs would otherwise let a name break the
// layout of every list it appears in, and truncating by byte could split a
// multi-byte character into invalid UTF-8.
func sanitise(raw string) string {
	var builder strings.Builder
	pendingSpace := false
	runes := 0

	for _, r := range raw {
		if r == '\n' || r == '\r' || r == '\t' || r == ' ' {
			pendingSpace = builder.Len() > 0
			continue
		}
		// Other C0/C1 controls, including the bidi overrides' cousins.
		if r < 0x20 || (r >= 0x7F && r <= 0x9F) {
			continue
		}
		if pendingSpace {
			if runes+1 > maxDisplayNameLength {
				break
			}
			builder.WriteRune(' ')
			runes++
			pendingSpace = false
		}
		if runes+1 > maxDisplayNameLength {
			break
		}
		builder.WriteRune(r)
		runes++
	}
	return builder.String()
}

func present(user *core.Record) map[string]any {
	return map[string]any{
		"id":           user.Id,
		"display_name": user.GetString("display_name"),
		"email":        user.GetString("email"),
		// The stored filename; internal/avatars writes it and the client builds
		// the `/api/files/users/{id}/{filename}` path.
		"avatar": user.GetString("avatar"),
		// Set via internal/contacts' settings route, surfaced here so the
		// Settings screen's toggle reflects the real, current value rather
		// than always opening on its default.
		"discoverable": user.GetBool("discoverable"),
		"phone":        user.GetString("phone"),
	}
}
