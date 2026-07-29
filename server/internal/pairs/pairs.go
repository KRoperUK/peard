// Package pairs implements Pear'd connections: invite codes, accept and leave.
//
// Routes (all require auth):
//
//	POST /api/peard/pairs/invite      { pair? }        -> { code, deep_link, expires, pair? }
//	POST /api/peard/pairs/accept      { code }         -> { pair }
//	POST /api/peard/pairs/leave       { pair? }        -> { ok }
//	POST /api/peard/pairs/remove      { pair, user }   -> { ok }
//	GET  /api/peard/connections                        -> { connections: [...] }
//	POST /api/peard/connections/mute  { pair, muted }  -> { ok, muted }
//
// A "connection" is a `pairs` row plus its `pair_members`. Two members is the
// 1:1 case the app started with; more than two is a group, which is why
// `pair_members` was a join table from the outset. A user may belong to several
// connections at once.
//
// An invite without a `pair` creates a new connection when accepted. An invite
// carrying a `pair` adds the accepting user to that existing connection, which
// is how a group grows.
package pairs

import (
	"crypto/rand"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

const inviteTTL = 7 * 24 * time.Hour

// maxMembers bounds a connection. Every new post fans out to every other
// member's devices, and the tally queries are per connection, so this keeps
// both bounded; it is also the widest a shared timeline stays legible.
const maxMembers = 12

// maxConnections bounds how many connections one user may join, so a single
// account cannot make the home screen's switcher (or its own fan-in) unbounded.
const maxConnections = 20

// Register binds the pairing routes and the invite-expiry cron job.
func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		g := se.Router.Group("/api/peard/pairs")
		g.POST("/invite", inviteHandler(app)).Bind(apis.RequireAuth())
		g.POST("/accept", acceptHandler(app)).Bind(apis.RequireAuth())
		g.POST("/leave", leaveHandler(app)).Bind(apis.RequireAuth())
		// Removing somebody else, which only an owner may do. Distinct from
		// /leave so the two cannot be confused for one another.
		g.POST("/remove", removeHandler(app)).Bind(apis.RequireAuth())

		// Not under /pairs: it describes the caller's connections rather than
		// acting on one.
		se.Router.GET("/api/peard/connections", connectionsHandler(app)).Bind(apis.RequireAuth())
		se.Router.POST("/api/peard/connections/mute", muteHandler(app)).Bind(apis.RequireAuth())
		return se.Next()
	})

	// Sweep stale invites every 15 minutes.
	app.Cron().MustAdd("peard-expire-invites", "*/15 * * * *", func() {
		invites, err := app.FindRecordsByFilter(
			"pair_invites",
			"status = 'pending' && expires < {:now}",
			"", 500, 0,
			dbx.Params{"now": types.NowDateTime().String()},
		)
		if err != nil {
			return
		}
		for _, inv := range invites {
			inv.Set("status", "expired")
			_ = app.Save(inv)
		}
	})
}

func inviteHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			Pair string `json:"pair" form:"pair"`
		}
		// A bodyless POST is the "new connection" case, so a bind failure is
		// only fatal when there was a body to read.
		if e.Request.ContentLength > 0 {
			if err := e.BindBody(&body); err != nil {
				return e.BadRequestError("invalid request body", err)
			}
		}
		pairID := strings.TrimSpace(body.Pair)

		if pairID == "" {
			if err := requireConnectionHeadroom(app, e.Auth.Id); err != nil {
				return e.BadRequestError(err.Error(), nil)
			}
		} else {
			// Inviting into a group: the inviter must already be in it, and it
			// must have room.
			if !isMember(app, pairID, e.Auth.Id) {
				return e.ForbiddenError("you are not a member of that connection", nil)
			}
			if err := requireMemberHeadroom(app, pairID); err != nil {
				return e.BadRequestError(err.Error(), nil)
			}
		}

		col, err := app.FindCollectionByNameOrId("pair_invites")
		if err != nil {
			return e.InternalServerError("pair_invites collection missing", err)
		}
		inv := core.NewRecord(col)
		code := newCode(6)
		inv.Set("code", code)
		inv.Set("inviter", e.Auth.Id)
		inv.Set("status", "pending")
		inv.Set("expires", time.Now().Add(inviteTTL).UTC().Format(types.DefaultDateLayout))
		if pairID != "" {
			inv.Set("pair", pairID)
		}
		if err := app.Save(inv); err != nil {
			return e.InternalServerError("failed to create invite", err)
		}
		res := map[string]any{
			"code":      code,
			"expires":   inv.GetString("expires"),
			"deep_link": "peard://pair/" + code,
		}
		if pairID != "" {
			res["pair"] = pairID
		}
		return e.JSON(http.StatusOK, res)
	}
}

func acceptHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			Code string `json:"code" form:"code"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}
		code := strings.ToUpper(strings.TrimSpace(body.Code))
		if code == "" {
			return e.BadRequestError("code is required", nil)
		}

		inv, err := app.FindFirstRecordByFilter("pair_invites",
			"code = {:code} && status = 'pending'", dbx.Params{"code": code})
		if err != nil || inv == nil {
			return e.NotFoundError("invite not found or already used", err)
		}
		if exp := inv.GetDateTime("expires"); !exp.IsZero() && exp.Time().Before(time.Now()) {
			inv.Set("status", "expired")
			_ = app.Save(inv)
			return e.BadRequestError("invite expired", nil)
		}

		inviterID := inv.GetString("inviter")
		existingPairID := inv.GetString("pair")

		if inviterID == e.Auth.Id {
			return e.BadRequestError("you cannot pear with yourself", nil)
		}
		if err := requireConnectionHeadroom(app, e.Auth.Id); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}

		// Joining an existing connection (a group invite).
		if existingPairID != "" {
			if isMember(app, existingPairID, e.Auth.Id) {
				return e.BadRequestError("you are already in that connection", nil)
			}
			if err := requireMemberHeadroom(app, existingPairID); err != nil {
				return e.BadRequestError(err.Error(), nil)
			}
			err = app.RunInTransaction(func(txApp core.App) error {
				if err := addMember(txApp, existingPairID, e.Auth.Id, "member"); err != nil {
					return err
				}
				inv.Set("status", "accepted")
				inv.Set("invitee", e.Auth.Id)
				return txApp.Save(inv)
			})
			if err != nil {
				return e.InternalServerError("failed to join connection", err)
			}
			return e.JSON(http.StatusOK, map[string]any{"pair": existingPairID})
		}

		// A fresh 1:1 connection between the inviter and the accepting user.
		if err := requireConnectionHeadroom(app, inviterID); err != nil {
			return e.BadRequestError("whoever invited you has too many connections", nil)
		}

		var pairID string
		err = app.RunInTransaction(func(txApp core.App) error {
			pairsCol, err := txApp.FindCollectionByNameOrId("pairs")
			if err != nil {
				return err
			}
			pair := core.NewRecord(pairsCol)
			if err := txApp.Save(pair); err != nil {
				return err
			}
			pairID = pair.Id

			if err := addMember(txApp, pair.Id, inviterID, "owner"); err != nil {
				return err
			}
			if err := addMember(txApp, pair.Id, e.Auth.Id, "member"); err != nil {
				return err
			}

			inv.Set("status", "accepted")
			inv.Set("invitee", e.Auth.Id)
			return txApp.Save(inv)
		})
		if err != nil {
			return e.InternalServerError("failed to create pair", err)
		}
		return e.JSON(http.StatusOK, map[string]any{"pair": pairID})
	}
}

func leaveHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			Pair string `json:"pair" form:"pair"`
		}
		if e.Request.ContentLength > 0 {
			if err := e.BindBody(&body); err != nil {
				return e.BadRequestError("invalid request body", err)
			}
		}
		pairID := strings.TrimSpace(body.Pair)

		var mem *core.Record
		var err error
		if pairID == "" {
			// No connection named: only unambiguous when the user has exactly
			// one, which is what an older client would have assumed.
			memberships, ferr := app.FindRecordsByFilter("pair_members",
				"user = {:user}", "", 2, 0, dbx.Params{"user": e.Auth.Id})
			if ferr != nil || len(memberships) == 0 {
				return e.NotFoundError("you are not pear'd with anyone", ferr)
			}
			if len(memberships) > 1 {
				return e.BadRequestError("you are in more than one connection; say which to leave", nil)
			}
			mem = memberships[0]
			pairID = mem.GetString("pair")
		} else {
			mem, err = app.FindFirstRecordByFilter("pair_members",
				"pair = {:pair} && user = {:user}",
				dbx.Params{"pair": pairID, "user": e.Auth.Id})
			if err != nil || mem == nil {
				return e.NotFoundError("you are not a member of that connection", err)
			}
		}

		if err := app.Delete(mem); err != nil {
			return e.InternalServerError("failed to leave connection", err)
		}
		// Delete the connection once empty (cascades to posts/reactions/kinds).
		remaining, _ := app.FindRecordsByFilter("pair_members",
			"pair = {:pair}", "", 1, 0, dbx.Params{"pair": pairID})
		if len(remaining) == 0 {
			if pair, err := app.FindRecordById("pairs", pairID); err == nil {
				_ = app.Delete(pair)
			}
		}
		return e.JSON(http.StatusOK, map[string]any{"ok": true})
	}
}

// removeHandler lets an owner remove somebody else from a connection.
//
// Deliberately separate from /leave. The `pair_members` DeleteRule is
// `user = @request.auth.id`, so the collection API can only ever delete your own
// membership; taking somebody out of a group is a different act with a different
// authority, and it happens here where that authority can be checked.
func removeHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			Pair string `json:"pair" form:"pair"`
			User string `json:"user" form:"user"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}
		pairID := strings.TrimSpace(body.Pair)
		userID := strings.TrimSpace(body.User)
		if pairID == "" || userID == "" {
			return e.BadRequestError("pair and user are required", nil)
		}
		if userID == e.Auth.Id {
			// Leaving is not removing: /leave also tidies up the connection when
			// it empties, and needs no ownership.
			return e.BadRequestError("use leave to remove yourself", nil)
		}

		caller, err := app.FindFirstRecordByFilter("pair_members",
			"pair = {:pair} && user = {:user}",
			dbx.Params{"pair": pairID, "user": e.Auth.Id})
		if err != nil || caller == nil {
			return e.NotFoundError("you are not a member of that connection", err)
		}
		if caller.GetString("role") != "owner" {
			return e.ForbiddenError("only the owner can remove somebody", nil)
		}

		target, err := app.FindFirstRecordByFilter("pair_members",
			"pair = {:pair} && user = {:user}",
			dbx.Params{"pair": pairID, "user": userID})
		if err != nil || target == nil {
			return e.NotFoundError("they are not in that connection", err)
		}
		if err := app.Delete(target); err != nil {
			return e.InternalServerError("failed to remove them", err)
		}
		// Their moments stay: the timeline is shared, and deleting half a
		// conversation because somebody left is not what anybody asked for.
		// authorLabel on the client names a former member "Someone".
		return e.JSON(http.StatusOK, map[string]any{"ok": true})
	}
}

// muteHandler silences push for one connection.
//
// It writes the single `muted` field on the caller's own membership. See the
// 1785369600_peard_muting migration for why this is a route rather than a
// collection UpdateRule.
func muteHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			Pair  string `json:"pair" form:"pair"`
			Muted bool   `json:"muted" form:"muted"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}
		pairID := strings.TrimSpace(body.Pair)
		if pairID == "" {
			return e.BadRequestError("pair is required", nil)
		}

		mem, err := app.FindFirstRecordByFilter("pair_members",
			"pair = {:pair} && user = {:user}",
			dbx.Params{"pair": pairID, "user": e.Auth.Id})
		if err != nil || mem == nil {
			return e.NotFoundError("you are not a member of that connection", err)
		}
		mem.Set("muted", body.Muted)
		if err := app.Save(mem); err != nil {
			return e.InternalServerError("failed to save the setting", err)
		}
		return e.JSON(http.StatusOK, map[string]any{"ok": true, "muted": body.Muted})
	}
}

// connectionsHandler describes every connection the caller belongs to, including
// the other members' display names.
//
// The names have to come from here because the `users` view rule is
// `id = @request.auth.id`: a client cannot read anybody else's record, so
// `expand=user` silently omits them and every unnamed connection would read
// "Partner" in the switcher. Only the resolved display name is returned — never
// the email — so learning who you share a connection with does not also hand out
// their address.
func connectionsHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		memberships, err := app.FindRecordsByFilter("pair_members",
			"user = {:user}", "created", maxConnections, 0,
			dbx.Params{"user": e.Auth.Id})
		if err != nil {
			return e.InternalServerError("could not read your connections", err)
		}

		out := make([]map[string]any, 0, len(memberships))
		for _, membership := range memberships {
			pairID := membership.GetString("pair")
			pair, err := app.FindRecordById("pairs", pairID)
			if err != nil {
				continue
			}

			members, err := app.FindRecordsByFilter("pair_members",
				"pair = {:pair}", "created", maxMembers, 0, dbx.Params{"pair": pairID})
			if err != nil {
				continue
			}

			people := make([]map[string]any, 0, len(members))
			for _, member := range members {
				userID := member.GetString("user")
				user, _ := app.FindRecordById("users", userID)
				people = append(people, map[string]any{
					"user":   userID,
					"name":   displayName(user),
					"role":   member.GetString("role"),
					"is_you": userID == e.Auth.Id,
				})
			}

			out = append(out, map[string]any{
				"pair":         pairID,
				"name":         pair.GetString("name"),
				"created":      pair.GetString("created"),
				"role":         membership.GetString("role"),
				"muted":        membership.GetBool("muted"),
				"member_count": len(members),
				"is_group":     len(members) > 2,
				"members":      people,
			})
		}
		return e.JSON(http.StatusOK, map[string]any{"connections": out})
	}
}

// displayName resolves a user to something printable: their display name, else
// the local part of their email, else a neutral fallback. Mirrors the same helper
// in internal/widget and internal/push.
func displayName(user *core.Record) string {
	if user == nil {
		return "Someone"
	}
	if name := user.GetString("display_name"); name != "" {
		return name
	}
	if email := user.GetString("email"); email != "" {
		if i := strings.Index(email, "@"); i > 0 {
			return email[:i]
		}
	}
	return "Someone"
}

func addMember(app core.App, pairID, userID, role string) error {
	col, err := app.FindCollectionByNameOrId("pair_members")
	if err != nil {
		return err
	}
	mem := core.NewRecord(col)
	mem.Set("pair", pairID)
	mem.Set("user", userID)
	mem.Set("role", role)
	return app.Save(mem)
}

func isMember(app core.App, pairID, userID string) bool {
	mem, err := app.FindFirstRecordByFilter("pair_members",
		"pair = {:pair} && user = {:user}",
		dbx.Params{"pair": pairID, "user": userID})
	return err == nil && mem != nil
}

func requireMemberHeadroom(app core.App, pairID string) error {
	members, err := app.FindRecordsByFilter("pair_members",
		"pair = {:pair}", "", maxMembers+1, 0, dbx.Params{"pair": pairID})
	if err != nil {
		return errors.New("could not count the connection's members")
	}
	if len(members) >= maxMembers {
		return errors.New("that connection is full")
	}
	return nil
}

func requireConnectionHeadroom(app core.App, userID string) error {
	memberships, err := app.FindRecordsByFilter("pair_members",
		"user = {:user}", "", maxConnections+1, 0, dbx.Params{"user": userID})
	if err != nil {
		return errors.New("could not count your connections")
	}
	if len(memberships) >= maxConnections {
		return errors.New("you have joined as many connections as Pear'd allows")
	}
	return nil
}

// Invite codes avoid visually ambiguous characters (no I, L, O, 0, 1).
const codeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

func newCode(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = codeAlphabet[int(b[i])%len(codeAlphabet)]
	}
	return string(b)
}
