package posts_test

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"

	"peard/internal/tallies"
)

// MARK: Creating a moment

func TestAMomentLoggedLiveHappenedNow(t *testing.T) {
	w := newWorld(t)

	post := w.create(t, w.aliceTok, "")

	assertNear(t, post.GetDateTime("happened_at"), time.Now())
	if rewound(post) {
		t.Error("rewound = true on a moment nobody rewound")
	}
}

func TestAMomentCanBeRewoundAFewHours(t *testing.T) {
	w := newWorld(t)
	at := time.Now().Add(-3 * time.Hour)

	post := w.create(t, w.aliceTok, `,"rewound":true,"happened_at":"`+iso(at)+`"`)

	assertNear(t, post.GetDateTime("happened_at"), at)
	if !rewound(post) {
		t.Error("rewound = false on a moment set three hours back")
	}
}

// The offline queue sends a moment late with the time it was tapped. It lands
// at that time, and it was not filled in after the fact, so no chip.
func TestALateSendKeepsItsTimeWithoutTheChip(t *testing.T) {
	w := newWorld(t)
	tapped := time.Now().Add(-2 * time.Hour)

	post := w.create(t, w.aliceTok, `,"happened_at":"`+iso(tapped)+`"`)

	assertNear(t, post.GetDateTime("happened_at"), tapped)
	if rewound(post) {
		t.Error("a late send came out rewound")
	}
}

// Claiming a rewind with no time to describe is meaningless.
func TestARewindClaimWithoutATimeIsIgnored(t *testing.T) {
	w := newWorld(t)

	post := w.create(t, w.aliceTok, `,"rewound":true`)

	if rewound(post) {
		t.Error("rewound = true with no happened_at")
	}
}

// A phone clock running a little fast is not refused, and is not stored ahead
// of when the moment arrived either.
func TestAClockSlightlyAheadIsPulledBackToArrival(t *testing.T) {
	w := newWorld(t)

	post := w.create(t, w.aliceTok, `,"happened_at":"`+iso(time.Now().Add(20*time.Second))+`"`)

	if post.GetDateTime("happened_at").Time().After(post.GetDateTime("created").Time()) {
		t.Errorf("happened_at %s is after created %s", post.GetString("happened_at"), post.GetString("created"))
	}
	if rewound(post) {
		t.Error("a moment from a fast clock reads as rewound")
	}
}

// Nudging the picker by a few seconds is not rewinding.
func TestAFewSecondsBackIsStillLive(t *testing.T) {
	w := newWorld(t)

	post := w.create(t, w.aliceTok, `,"rewound":true,"happened_at":"`+iso(time.Now().Add(-20*time.Second))+`"`)
	if rewound(post) {
		t.Error("rewound = true for a moment 20 seconds back")
	}
}

func TestAMomentCannotBeRewoundMoreThanADay(t *testing.T) {
	w := newWorld(t)

	status, body := w.createRaw(t, w.aliceTok, `,"happened_at":"`+iso(time.Now().Add(-25*time.Hour))+`"`)
	if status != http.StatusBadRequest {
		t.Fatalf("25 hours back: %d %s, want 400", status, body)
	}
}

func TestAMomentCannotHappenInTheFuture(t *testing.T) {
	w := newWorld(t)

	status, body := w.createRaw(t, w.aliceTok, `,"happened_at":"`+iso(time.Now().Add(10*time.Minute))+`"`)
	if status != http.StatusBadRequest {
		t.Fatalf("10 minutes ahead: %d %s, want 400", status, body)
	}
}

// The widget writes posts with app.Save rather than through the collection
// endpoint. It still gets a time.
func TestAMomentSavedOutsideARequestStillGetsATime(t *testing.T) {
	w := newWorld(t)

	post := w.reload(t, w.bobPost.Id)
	assertNear(t, post.GetDateTime("happened_at"), time.Now())
	if rewound(post) {
		t.Error("rewound = true on a fixture nobody rewound")
	}
}

// MARK: Editing the time

func TestAnAuthorCanRewindTheirMomentAfterwards(t *testing.T) {
	w := newWorld(t)
	at := time.Now().Add(-2 * time.Hour)

	status, body := w.edit(t, w.aliceTok, `{"post":"`+w.alicePost.Id+`","happened_at":"`+iso(at)+`"}`)
	if status != 200 {
		t.Fatalf("edit: %d %s", status, body)
	}
	got := w.reload(t, w.alicePost.Id)
	assertNear(t, got.GetDateTime("happened_at"), at)
	if !rewound(got) {
		t.Error("rewound = false after rewinding two hours")
	}
	if got.GetString("note") != "at the pub" {
		t.Errorf("note = %q — a time change must not touch the note", got.GetString("note"))
	}
}

// The window is measured from when the moment was logged, so a moment logged
// yesterday evening can still go back to yesterday afternoon today, but not to
// the day before.
func TestTheWindowIsMeasuredFromWhenItWasLogged(t *testing.T) {
	w := newWorld(t)
	w.backdate(t, w.alicePost, 20*time.Hour)
	logged := w.reload(t, w.alicePost.Id).GetDateTime("created").Time()

	ok := logged.Add(-23 * time.Hour)
	if status, body := w.edit(t, w.aliceTok, `{"post":"`+w.alicePost.Id+`","happened_at":"`+iso(ok)+`"}`); status != 200 {
		t.Fatalf("23h before logging: %d %s", status, body)
	}

	tooFar := logged.Add(-25 * time.Hour)
	if status, body := w.edit(t, w.aliceTok, `{"post":"`+w.alicePost.Id+`","happened_at":"`+iso(tooFar)+`"}`); status != http.StatusBadRequest {
		t.Fatalf("25h before logging: %d %s, want 400", status, body)
	}

	// After it was logged is the future, as far as the moment is concerned.
	after := logged.Add(2 * time.Hour)
	if status, body := w.edit(t, w.aliceTok, `{"post":"`+w.alicePost.Id+`","happened_at":"`+iso(after)+`"}`); status != http.StatusBadRequest {
		t.Fatalf("after logging: %d %s, want 400", status, body)
	}
}

func TestARewindCanBeUndone(t *testing.T) {
	w := newWorld(t)
	w.edit(t, w.aliceTok, `{"post":"`+w.alicePost.Id+`","happened_at":"`+iso(time.Now().Add(-2*time.Hour))+`"}`)

	status, body := w.edit(t, w.aliceTok, `{"post":"`+w.alicePost.Id+`","happened_at":""}`)
	if status != 200 {
		t.Fatalf("undo: %d %s", status, body)
	}
	got := w.reload(t, w.alicePost.Id)
	if rewound(got) {
		t.Error("rewound = true after putting it back")
	}
	if got.GetString("happened_at") != got.GetString("created") {
		t.Errorf("happened_at = %s, want created %s", got.GetString("happened_at"), got.GetString("created"))
	}
}

func TestSomebodyElsesMomentCannotBeRewound(t *testing.T) {
	w := newWorld(t)

	status, _ := w.edit(t, w.bobTok, `{"post":"`+w.alicePost.Id+`","happened_at":"`+iso(time.Now().Add(-time.Hour))+`"}`)
	if status != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", status)
	}
	if rewound(w.reload(t, w.alicePost.Id)) {
		t.Error("bob rewound alice's moment")
	}
}

// MARK: Where it counts

// A moment logged now but rewound to before "today" started counts in the
// all-time tally and not today's. `created` would say otherwise.
func TestTalliesCountWhenAMomentHappened(t *testing.T) {
	w := newWorld(t, tallies.Register)

	w.create(t, w.aliceTok, `,"event_kind":"tea","happened_at":"`+iso(time.Now().Add(-3*time.Hour))+`"`)

	day := time.Now().Add(-time.Hour)
	q := url.Values{"pair": {w.pair.Id}, "day": {iso(day)}, "week": {iso(day)}, "month": {iso(day)}}
	status, body := w.do(t, http.MethodGet, "/api/peard/tallies?"+q.Encode(), w.aliceTok, "")
	if status != 200 {
		t.Fatalf("tallies: %d %s", status, body)
	}
	var got struct {
		Kinds []struct {
			Kind string `json:"kind"`
			Mine struct {
				Day int `json:"day"`
				All int `json:"all"`
			} `json:"mine"`
		} `json:"kinds"`
	}
	if err := json.Unmarshal([]byte(body), &got); err != nil {
		t.Fatalf("decode: %v — %s", err, body)
	}
	for _, k := range got.Kinds {
		if k.Kind != "tea" {
			continue
		}
		if k.Mine.All != 1 || k.Mine.Day != 0 {
			t.Fatalf("tea = day %d all %d, want day 0 all 1", k.Mine.Day, k.Mine.All)
		}
		return
	}
	t.Fatalf("no tea in %s", body)
}

// MARK: helpers

func (w *world) create(t *testing.T, token, extra string) *core.Record {
	t.Helper()
	status, body := w.createRaw(t, token, extra)
	if status != 200 {
		t.Fatalf("create: %d %s", status, body)
	}
	var out struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		t.Fatalf("decode create: %v", err)
	}
	return w.reload(t, out.ID)
}

// createRaw writes an event through the collection endpoint, the way the app
// does. `extra` is a fragment of further fields (",\"key\":value,…") that is
// merged over the defaults, so it may override event_kind. Merged, not spliced
// on: splicing sent event_kind twice, and PocketBase 0.40 rejects a body with a
// duplicate key.
func (w *world) createRaw(t *testing.T, token, extra string) (int, string) {
	t.Helper()
	fields := map[string]any{"pair": w.pair.Id, "author": w.alice.Id, "type": "event", "event_kind": "beer"}
	if extra != "" {
		var more map[string]any
		if err := json.Unmarshal([]byte("{"+strings.TrimPrefix(extra, ",")+"}"), &more); err != nil {
			t.Fatalf("extra fields %q: %v", extra, err)
		}
		for k, v := range more {
			fields[k] = v
		}
	}
	body, err := json.Marshal(fields)
	if err != nil {
		t.Fatalf("encode create: %v", err)
	}
	return w.do(t, http.MethodPost, "/api/collections/posts/records", token, string(body))
}

func rewound(post *core.Record) bool {
	return post.GetBool("rewound")
}

func iso(t time.Time) string { return t.UTC().Format(time.RFC3339) }

func assertNear(t *testing.T, got types.DateTime, want time.Time) {
	t.Helper()
	if d := got.Time().Sub(want); d < -2*time.Second || d > 2*time.Second {
		t.Fatalf("happened_at = %s, want about %s", got, want.UTC())
	}
}
