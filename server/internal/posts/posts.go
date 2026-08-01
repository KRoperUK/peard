// Package posts implements editing a moment after it has been logged.
//
// Route (requires auth):
//
//	POST /api/peard/posts/edit  { post, note?, event_kind? } -> { ok, note, event_kind }
//
// Deletion is deliberately *not* here. `posts.DeleteRule` is already
// `author = @request.auth.id`, so the ordinary collection endpoint does it, and
// a second door onto the same act would be a second place for the authority
// rule to drift.
//
// Editing needs a route because a rule cannot say *which fields* may change.
// Giving `posts` an UpdateRule of "author = @request.auth.id" would also let an
// author move a moment into a different connection, or reassign it to somebody
// else, or swap a photo for an event — none of which anybody asked for, and all
// of which the shared timeline would then have to be trusted not to show. So the
// UpdateRule stays nil and this route writes the two fields that are a person's
// own account of what happened: the note, and which moment it was.
package posts

import (
	"net/http"
	"strings"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// Matches the `note` field's Max, so an over-long note is refused with a
// sentence rather than a PocketBase validation blob.
const maxNoteLength = 280

// Matches the `event_kind` field's Max.
const maxKindLength = 40

func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.POST("/api/peard/posts/edit", editHandler(app)).Bind(apis.RequireAuth())
		return se.Next()
	})
}

func editHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		// Pointers, so "not sent" is distinguishable from "sent empty". Clearing
		// a note is a real edit — somebody took the words back — and it has to be
		// possible to say that without it looking like "leave the note alone".
		var body struct {
			Post      string  `json:"post" form:"post"`
			Note      *string `json:"note" form:"note"`
			EventKind *string `json:"event_kind" form:"event_kind"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}

		postID := strings.TrimSpace(body.Post)
		if postID == "" {
			return e.BadRequestError("post is required", nil)
		}
		if body.Note == nil && body.EventKind == nil {
			return e.BadRequestError("nothing to change", nil)
		}

		post, err := app.FindRecordById("posts", postID)
		if err != nil || post == nil {
			return e.NotFoundError("that moment no longer exists", err)
		}
		// Author only, and the same answer whether the moment belongs to
		// somebody else or to a connection the caller is not in: "not yours" and
		// "not visible to you" are the same fact from out here, and telling them
		// apart would confirm a post id to somebody with no business knowing it.
		if post.GetString("author") != e.Auth.Id {
			return e.ForbiddenError("you can only edit your own moments", nil)
		}

		if body.Note != nil {
			note := strings.TrimSpace(*body.Note)
			if len(note) > maxNoteLength {
				return e.BadRequestError("that note is too long", nil)
			}
			post.Set("note", note)
		}

		if body.EventKind != nil {
			// A photo has no moment kind, and giving it one would put a moment
			// in the tallies that nobody logged.
			if post.GetString("type") != "event" {
				return e.BadRequestError("only a logged moment has a kind to change", nil)
			}
			kind := strings.TrimSpace(*body.EventKind)
			if kind == "" {
				return e.BadRequestError("a moment needs a kind", nil)
			}
			if len(kind) > maxKindLength {
				return e.BadRequestError("that kind is too long", nil)
			}
			post.Set("event_kind", kind)
		}

		if err := app.Save(post); err != nil {
			return e.InternalServerError("failed to save the edit", err)
		}

		// Nothing is pushed. An edit is a correction to something the others have
		// already been told about, and a second notification for the same moment
		// reads as a second moment.
		return e.JSON(http.StatusOK, map[string]any{
			"ok":         true,
			"note":       post.GetString("note"),
			"event_kind": post.GetString("event_kind"),
			"updated":    post.GetString("updated"),
		})
	}
}
