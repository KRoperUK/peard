// Read state: POST /api/peard/connections/seen, and the `unread` count that
// GET /api/peard/connections reports from it.
//
// External to `pairs` for the same reason as lifecycle_test.go — the real schema
// comes from blank-importing `peard/migrations`, which imports `peard/internal/pairs`.
package pairs_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"

	"peard/internal/pairs"
)

// unreadFor pulls one connection's `unread` out of GET /api/peard/connections,
// which is the number the app actually draws — asserting on the helper alone
// would not catch the field being dropped from the response.
func unreadFor(t *testing.T, w *lifeWorld, token, pairID string) int {
	t.Helper()
	code, body := w.do(t, "GET", "/api/peard/connections", token, "")
	if code != 200 {
		t.Fatalf("connections: got %d, body %s", code, body)
	}
	var parsed struct {
		Connections []struct {
			Pair   string `json:"pair"`
			Unread int    `json:"unread"`
		} `json:"connections"`
	}
	if err := json.Unmarshal([]byte(body), &parsed); err != nil {
		t.Fatalf("decode connections: %v (body %s)", err, body)
	}
	for _, c := range parsed.Connections {
		if c.Pair == pairID {
			return c.Unread
		}
	}
	t.Fatalf("connection %s not in %s", pairID, body)
	return 0
}

// backdate moves a record's `created` into the past.
//
// Used instead of sleeping between a join and a post. `created > since` is
// strict and PocketBase stamps to the millisecond, so a membership and a post
// written in the same tick compare as not-after — real life always has a gap,
// but a test that relies on one is a test that fails on a fast machine.
//
// Raw SQL rather than record.Set: `created` is an AutodateField, and the field
// ignores writes through the record API. Setting it and saving is silently a
// no-op — which is how an earlier version of this helper made
// TestAnUnreadMomentDoesNotExpire pass while proving nothing. The timestamps
// migration reaches for SQL to stamp these columns for the same reason.
func backdate(t *testing.T, w *lifeWorld, collection string, record *core.Record, by time.Duration) {
	t.Helper()
	want := types.NowDateTime().Add(-by)
	_, err := w.app.DB().
		NewQuery("UPDATE {{"+collection+"}} SET [[created]] = {:t} WHERE [[id]] = {:id}").
		Bind(map[string]any{"t": want.String(), "id": record.Id}).
		Execute()
	if err != nil {
		t.Fatalf("backdate %s/%s: %v", collection, record.Id, err)
	}

	// Assert it landed. A helper whose failure mode is "the test passes anyway"
	// has to check its own work.
	fresh, err := w.app.FindRecordById(collection, record.Id)
	if err != nil {
		t.Fatalf("re-read %s/%s: %v", collection, record.Id, err)
	}
	if got := fresh.GetDateTime("created"); got.String() != want.String() {
		t.Fatalf("backdate did not stick: %s is %s, want %s", collection, got, want)
	}
}

// persisted is a DateTime at the precision the database keeps.
//
// `types.NowDateTime()` holds sub-millisecond precision in memory that the
// column does not, so an in-memory value and its own round-trip are unequal
// while printing identically — which is a genuinely baffling five minutes if you
// compare the two directly.
func persisted(t *testing.T, at types.DateTime) types.DateTime {
	t.Helper()
	out, err := types.ParseDateTime(at.String())
	if err != nil {
		t.Fatalf("parse %s: %v", at, err)
	}
	return out
}

// membership re-reads a membership from the database, so assertions see what was
// persisted rather than an in-memory copy.
func membership(t *testing.T, w *lifeWorld, pairID, userID string) *core.Record {
	t.Helper()
	rec, err := w.app.FindFirstRecordByFilter("pair_members",
		"pair = {:pair} && user = {:user}",
		map[string]any{"pair": pairID, "user": userID})
	if err != nil || rec == nil {
		t.Fatalf("membership %s/%s: %v", pairID, userID, err)
	}
	return rec
}

// Your own moments are not news to you. Counting them would make the badge tick
// up as you logged, which is the opposite of what a badge is for.
func TestYourOwnMomentsAreNeverUnread(t *testing.T) {
	w := newLifeWorld(t)

	// seed() already gave `flatmates` one post authored by Alice.
	if got := unreadFor(t, w, w.aliceTok, w.flatmates.Id); got != 0 {
		t.Fatalf("own moment counted as unread: got %d, want 0", got)
	}
}

func TestSomebodyElsesMomentIsUnreadUntilSeen(t *testing.T) {
	w := newLifeWorld(t)
	w.addMember(t, w.flatmates, w.bob, "member")
	w.newPost(t, w.flatmates, w.bob, "coffee", "from Bob")

	if got := unreadFor(t, w, w.aliceTok, w.flatmates.Id); got != 1 {
		t.Fatalf("before seen: got %d, want 1", got)
	}

	code, body := w.do(t, "POST", "/api/peard/connections/seen", w.aliceTok,
		`{"pair":"`+w.flatmates.Id+`"}`)
	if code != 200 {
		t.Fatalf("seen: got %d, body %s", code, body)
	}

	if got := unreadFor(t, w, w.aliceTok, w.flatmates.Id); got != 0 {
		t.Fatalf("after seen: got %d, want 0", got)
	}
}

// The bug this whole feature replaces: the old count was "posted in the last 24
// hours", so it went to zero on its own. An unread moment has to stay unread for
// as long as it takes somebody to look at it.
func TestAnUnreadMomentDoesNotExpire(t *testing.T) {
	w := newLifeWorld(t)
	w.addMember(t, w.flatmates, w.bob, "member")
	post := w.newPost(t, w.flatmates, w.bob, "coffee", "a week ago")

	// Well past the day the old implementation counted within. Alice's own
	// membership predates it, so the join-date fallback does not hide the post.
	backdate(t, w, "pair_members", membership(t, w, w.flatmates.Id, w.alice.Id), 30*24*time.Hour)
	backdate(t, w, "posts", post, 7*24*time.Hour)

	if got := unreadFor(t, w, w.aliceTok, w.flatmates.Id); got != 1 {
		t.Fatalf("week-old unread moment: got %d, want 1", got)
	}
}

// Joining a five-year-old group must not hand you a badge of everything ever
// posted in it. With no `last_seen_at`, the cut-off is the join date.
func TestANewMemberDoesNotInheritTheBacklog(t *testing.T) {
	w := newLifeWorld(t)
	// The seeded post by Alice predates Bob's membership by an hour.
	backdate(t, w, "posts", w.post, 2*time.Hour)
	joined := w.addMember(t, w.flatmates, w.bob, "member")
	backdate(t, w, "pair_members", joined, time.Hour)

	if got := unreadFor(t, w, w.bobTok, w.flatmates.Id); got != 0 {
		t.Fatalf("backlog inherited: got %d, want 0", got)
	}

	w.newPost(t, w.flatmates, w.alice, "beer", "after Bob joined")
	if got := unreadFor(t, w, w.bobTok, w.flatmates.Id); got != 1 {
		t.Fatalf("post after joining: got %d, want 1", got)
	}
}

// Marking one connection read must not touch another. The rail marks each face
// separately, so a stamp that leaked across connections would silently clear
// moments the user never saw.
func TestSeenIsScopedToOneConnection(t *testing.T) {
	w := newLifeWorld(t)
	w.addMember(t, w.flatmates, w.bob, "member")
	// Backdated so both of Bob's moments in `elsewhere` — the seeded one and the
	// one below — land after Alice joined it.
	backdate(t, w, "pair_members", w.addMember(t, w.elsewhere, w.alice, "member"), time.Hour)
	w.newPost(t, w.flatmates, w.bob, "coffee", "here")
	w.newPost(t, w.elsewhere, w.bob, "coffee", "there")

	code, body := w.do(t, "POST", "/api/peard/connections/seen", w.aliceTok,
		`{"pair":"`+w.flatmates.Id+`"}`)
	if code != 200 {
		t.Fatalf("seen: got %d, body %s", code, body)
	}

	if got := unreadFor(t, w, w.aliceTok, w.flatmates.Id); got != 0 {
		t.Fatalf("stamped connection: got %d, want 0", got)
	}
	// Two: the one seeded into `elsewhere` and the one added above, both Bob's.
	if got := unreadFor(t, w, w.aliceTok, w.elsewhere.Id); got != 2 {
		t.Fatalf("other connection cleared too: got %d, want 2", got)
	}
}

// A moment posted after the stamp is unread again — the stamp is a watermark,
// not a one-time dismissal.
func TestAMomentAfterTheStampIsUnreadAgain(t *testing.T) {
	w := newLifeWorld(t)
	w.addMember(t, w.flatmates, w.bob, "member")

	code, _ := w.do(t, "POST", "/api/peard/connections/seen", w.aliceTok,
		`{"pair":"`+w.flatmates.Id+`"}`)
	if code != 200 {
		t.Fatalf("seen: got %d", code)
	}

	// The stamp has whole-millisecond resolution; without this the new post can
	// land inside the same tick and compare as not-after.
	time.Sleep(5 * time.Millisecond)
	w.newPost(t, w.flatmates, w.bob, "coffee", "after the stamp")

	if got := unreadFor(t, w, w.aliceTok, w.flatmates.Id); got != 1 {
		t.Fatalf("post after stamp: got %d, want 1", got)
	}
}

// The stamp comes from the server's clock, because it is compared against
// `posts.created`, which the server also writes. A device clock running fast
// would otherwise mark moments read before they were posted.
func TestSeenStampsTheServerClock(t *testing.T) {
	w := newLifeWorld(t)
	before := persisted(t, types.NowDateTime())

	code, body := w.do(t, "POST", "/api/peard/connections/seen", w.aliceTok,
		`{"pair":"`+w.flatmates.Id+`","at":"1999-01-01 00:00:00.000Z"}`)
	if code != 200 {
		t.Fatalf("seen: got %d, body %s", code, body)
	}

	stamped := membership(t, w, w.flatmates.Id, w.alice.Id).GetDateTime("last_seen_at")
	if stamped.Before(before) {
		t.Fatalf("stamp %s predates the request (%s) — a body-supplied time was honoured",
			stamped, before)
	}
	if !strings.Contains(body, "last_seen_at") {
		t.Fatalf("response omits the stamp it wrote: %s", body)
	}
}

func TestSeenRefusesAConnectionYouAreNotIn(t *testing.T) {
	w := newLifeWorld(t)

	// Bob is in `elsewhere`, not `flatmates`.
	code, _ := w.do(t, "POST", "/api/peard/connections/seen", w.bobTok,
		`{"pair":"`+w.flatmates.Id+`"}`)
	if code != 404 {
		t.Fatalf("got %d, want 404", code)
	}

	if rec := membership(t, w, w.flatmates.Id, w.alice.Id); !rec.GetDateTime("last_seen_at").IsZero() {
		t.Fatalf("a non-member's request stamped somebody else's membership")
	}
}

func TestSeenRequiresAuth(t *testing.T) {
	w := newLifeWorld(t)

	code, _ := w.do(t, "POST", "/api/peard/connections/seen", "",
		`{"pair":"`+w.flatmates.Id+`"}`)
	if code != 401 && code != 403 {
		t.Fatalf("got %d, want 401 or 403", code)
	}
}

func TestSeenRequiresAPair(t *testing.T) {
	w := newLifeWorld(t)

	code, _ := w.do(t, "POST", "/api/peard/connections/seen", w.aliceTok, `{}`)
	if code != 400 {
		t.Fatalf("got %d, want 400", code)
	}
}

// UnreadSince is exported so the push badge and the connections route cannot
// drift apart. Both fallbacks are asserted here because the badge has no test
// of its own that would catch a change to them.
func TestUnreadSinceFallsBackToTheJoinDate(t *testing.T) {
	w := newLifeWorld(t)
	mem := membership(t, w, w.flatmates.Id, w.alice.Id)

	if got := pairs.UnreadSince(mem); !got.Equal(mem.GetDateTime("created")) {
		t.Fatalf("never seen: got %s, want the join date %s", got, mem.GetDateTime("created"))
	}

	stamp := persisted(t, types.NowDateTime())
	mem.Set("last_seen_at", stamp)
	if err := w.app.Save(mem); err != nil {
		t.Fatalf("save stamp: %v", err)
	}
	if got := pairs.UnreadSince(membership(t, w, w.flatmates.Id, w.alice.Id)); !got.Equal(stamp) {
		t.Fatalf("seen: got %s, want %s", got, stamp)
	}
}
