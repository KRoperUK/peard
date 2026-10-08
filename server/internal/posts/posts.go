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
// there is a time more than a minute back for it to describe. And it checks
// that an answer to a photo points at a photo in the same connection — see
// CheckReplyTo. And that an `amount` — the millilitres in a glass of water —
// only rides on a moment, within reason; see CheckAmount.
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
	"unicode/utf8"

	"peard/internal/moments"

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

// The most one moment may carry, in millilitres. Matches the `amount` field's
// Max. Five litres in one go is a typo or a joke, and either would sit in the
// day's total all day.
const maxAmount = 5000

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
		if msg := CheckReplyTo(e.App, e.Record); msg != "" {
			return e.BadRequestError(msg, nil)
		}
		if msg := CheckAmount(e.Record); msg != "" {
			return e.BadRequestError(msg, nil)
		}
		if msg := CheckEventKind(e.App, e.Record); msg != "" {
			return e.BadRequestError(msg, nil)
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
			// Runes, not bytes: the field's Max is 280 characters, so a byte
			// count would reject an emoji or non-Latin note far short of it.
			if utf8.RuneCountInString(note) > maxNoteLength {
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
			if utf8.RuneCountInString(kind) > maxKindLength {
				return e.BadRequestError("that kind is too long", nil)
			}
			// An unknown kind must not reach the tallies, where it would be
			// counted as a real moment nobody logged. Validate against the
			// built-in kinds plus this connection's own moment_kinds (#347).
			if !moments.IsKnownKind(app, post.GetString("pair"), kind) {
				return e.BadRequestError("that is not a known moment kind", nil)
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

// CheckReplyTo returns why a post's `reply_to` is refused, or "" when it is
// fine or unset.
//
// An answer is to a photo — that is all anybody asked to answer — and it is in
// the photo's own connection. The CreateRule keeps a post inside a connection
// its author is in, but says nothing about what it points at, and a reply
// pointing across connections would put one group's photo, thumbnail and all,
// in front of another. Words or a photo, never a moment: a moment counts in
// the tallies, and answering a photo is not doing anything.
func CheckReplyTo(app core.App, post *core.Record) string {
	targetID := post.GetString("reply_to")
	if targetID == "" {
		return ""
	}
	if kind := post.GetString("type"); kind != noteType && kind != "photo" {
		return "only words or a photo can answer a photo"
	}
	// The same answer for a photo that has gone and one in a connection the
	// caller is not in, so a post id cannot be confirmed by guessing at it.
	target, err := app.FindRecordById("posts", targetID)
	if err != nil || target == nil || target.GetString("pair") != post.GetString("pair") {
		return "that photo no longer exists"
	}
	if target.GetString("type") != "photo" && target.GetString("media") == "" {
		return "only a photo can be answered"
	}
	return ""
}

// CheckAmount returns why a post's `amount` is refused, or "" when it is fine
// or unset. Zero is unset: it is what PocketBase stores for a number nobody gave.
//
// An amount is a fact about something that was done, so it rides on a moment
// and nothing else — a photo or a reply with one would count in no total and
// mean nothing. It is a whole number of millilitres, because that is what the
// day's total adds up.
func CheckAmount(post *core.Record) string {
	amount := post.GetInt("amount")
	switch {
	case amount == 0:
		return ""
	case amount < 0:
		return "an amount cannot be negative"
	case amount > maxAmount:
		return "an amount can be at most 5000 ml"
	case post.GetString("type") != "event":
		return "only a moment can carry an amount"
	}
	return ""
}

// CheckEventKind returns why a post's `event_kind` is refused, or "" when it is
// fine or does not apply.
//
// A free-text kind that is neither a built-in nor one of the connection's own
// moment_kinds would be counted in the tallies and the recap as a real moment
// nobody logged (#347), so an unknown kind is refused at write time. Only an
// `event` carries a kind — a photo or a reply has none — and an event with no
// kind is left to the field's own required check, not second-guessed here.
func CheckEventKind(app core.App, post *core.Record) string {
	if post.GetString("type") != "event" {
		return ""
	}
	kind := strings.TrimSpace(post.GetString("event_kind"))
	if kind == "" {
		return ""
	}
	if !moments.IsKnownKind(app, post.GetString("pair"), kind) {
		return "that is not a known moment kind"
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
