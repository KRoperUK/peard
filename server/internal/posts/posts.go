// Package posts implements editing a moment after it has been logged.
//
// Route (requires auth):
//
//	POST /api/peard/posts/edit  { post, note?, event_kind?, happened_at? }
//	                            -> { ok, note, event_kind, happened_at, rewound, updated }
//
// It also owns `happened_at` and `rewound` on every create, whichever door the
// moment came through. `happened_at` defaults to now and may be set up to 24
// hours back — by a person picking a time, or by the offline queue sending a
// moment late with the time it was tapped. `rewound` tells those apart: it is
// what the client says (true only for a picked time), and only stands when
// there is a time more than a minute back for it to describe.
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
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Matches the `note` field's Max, so an over-long note is refused with a
// sentence rather than a PocketBase validation blob.
const maxNoteLength = 280

// A post that is only words — a reply typed into a notification. The words are
// the whole of it, so one without any is refused rather than drawn as a blank.
const noteType = "note"

const emptyReply = "a reply needs something in it"

// Matches the `event_kind` field's Max.
const maxKindLength = 40

// How far back a moment can be rewound, measured from when it was logged.
const maxRewind = 24 * time.Hour

// Slack for a phone's clock running a little ahead of or behind the server's,
// so "now" on the device is not refused as the future.
const clockSkew = time.Minute

// A picked time less than this far back is not worth a chip: the picker opens
// on now, and a few seconds' fiddling with it is not a rewind.
const rewoundAfter = time.Minute

func Register(app core.App) {
	app.OnRecordCreateRequest("posts").BindFunc(func(e *core.RecordRequestEvent) error {
		if msg := CheckHappenedAt(e.Record.GetDateTime("happened_at"), time.Now()); msg != "" {
			return e.BadRequestError(msg, nil)
		}
		if e.Record.GetString("type") == noteType && strings.TrimSpace(e.Record.GetString("note")) == "" {
			return e.BadRequestError(emptyReply, nil)
		}
		return e.Next()
	})
	app.OnRecordCreate("posts").BindFunc(func(e *core.RecordEvent) error {
		stampHappenedAt(e.Record, time.Now())
		return e.Next()
	})

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
			Post       string  `json:"post" form:"post"`
			Note       *string `json:"note" form:"note"`
			EventKind  *string `json:"event_kind" form:"event_kind"`
			HappenedAt *string `json:"happened_at" form:"happened_at"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}

		postID := strings.TrimSpace(body.Post)
		if postID == "" {
			return e.BadRequestError("post is required", nil)
		}
		if body.Note == nil && body.EventKind == nil && body.HappenedAt == nil {
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
			if note == "" && post.GetString("type") == noteType {
				return e.BadRequestError(emptyReply, nil)
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

		if body.HappenedAt != nil {
			// Measured from `created`, not from now: the window is 24 hours before
			// the moment was logged, and editing it tomorrow does not move that.
			logged := post.GetDateTime("created").Time()
			raw := strings.TrimSpace(*body.HappenedAt)
			if raw == "" {
				// Empty puts it back to when it was logged.
				post.Set("happened_at", logged)
				post.Set("rewound", false)
			} else {
				at, err := types.ParseDateTime(raw)
				if err != nil || at.IsZero() {
					return e.BadRequestError("that time could not be read", err)
				}
				if msg := CheckHappenedAt(at, logged); msg != "" {
					return e.BadRequestError(msg, nil)
				}
				// Editing the time is choosing it, so an edit far enough back is
				// a rewind whatever the moment was before.
				setHappenedAt(post, at.Time(), logged, true)
			}
		}

		if err := app.Save(post); err != nil {
			return e.InternalServerError("failed to save the edit", err)
		}

		// Nothing is pushed. An edit is a correction to something the others have
		// already been told about, and a second notification for the same moment
		// reads as a second moment.
		return e.JSON(http.StatusOK, map[string]any{
			"ok":          true,
			"note":        post.GetString("note"),
			"event_kind":  post.GetString("event_kind"),
			"happened_at": post.GetString("happened_at"),
			"rewound":     post.GetBool("rewound"),
			"updated":     post.GetString("updated"),
		})
	}
}

// CheckHappenedAt returns why a requested time is refused, or "" when it is
// fine. A zero time is fine: it means "now", and stampHappenedAt fills it in.
// Exported for routes that create posts with app.Save, which the create-request
// hook below does not see — the widget's moment route.
func CheckHappenedAt(at types.DateTime, logged time.Time) string {
	if at.IsZero() {
		return ""
	}
	switch t := at.Time(); {
	case t.After(logged.Add(clockSkew)):
		return "a moment cannot happen in the future"
	case t.Before(logged.Add(-maxRewind - clockSkew)):
		return "a moment can only be rewound up to 24 hours"
	}
	return ""
}

// stampHappenedAt fills in a new moment's time — now, unless the request gave
// one — and settles `rewound` against it.
func stampHappenedAt(post *core.Record, now time.Time) {
	claimed := post.GetBool("rewound")
	at := post.GetDateTime("happened_at")
	if at.IsZero() {
		setHappenedAt(post, now, now, false)
		return
	}
	setHappenedAt(post, at.Time(), now, claimed)
}

// setHappenedAt never lets a moment happen after it was logged: a phone clock a
// few seconds fast is pulled back to the arrival time rather than stored ahead.
// `picked` is whether a person chose the time; it becomes the chip only when
// the time is far enough back to be worth saying so.
func setHappenedAt(post *core.Record, at, logged time.Time, picked bool) {
	if at.After(logged) {
		at = logged
	}
	post.Set("happened_at", at)
	post.Set("rewound", picked && logged.Sub(at) > rewoundAfter)
}
