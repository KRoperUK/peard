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

// An invite code is a bearer credential with no second factor, so it is meant to
// stop working quickly and then stop existing. These cover both halves: that the
// codes this server issues are short-lived, and that expired ones are actually
// removed rather than left lying around with a different status on them.

func TestIssuedInvitesExpireWithinADay(t *testing.T) {
	w := newLifeWorld(t)

	status, body := w.do(t, "POST", "/api/peard/pairs/invite", w.aliceTok, "")
	if status != 200 {
		t.Fatalf("create invite: %d %s", status, body)
	}

	var res struct {
		Code    string `json:"code"`
		Expires string `json:"expires"`
	}
	if err := json.Unmarshal([]byte(body), &res); err != nil {
		t.Fatalf("decode invite: %v (%s)", err, body)
	}
	expires, err := types.ParseDateTime(res.Expires)
	if err != nil {
		t.Fatalf("parse expires %q: %v", res.Expires, err)
	}

	life := time.Until(expires.Time())
	// A window rather than an equality: the clock moves between the handler
	// stamping the row and this line reading it.
	if life > 24*time.Hour || life < 23*time.Hour {
		t.Fatalf("invite lasts %v, want about 24h", life)
	}
}

func TestTheSweepDeletesExpiredInvites(t *testing.T) {
	w := newLifeWorld(t)
	stale := w.newInviteAt(t, "STALE1", "pending", w.hoursAgo(1))

	deleted, err := pairs.DeleteExpiredInvites(w.app, types.NowDateTime())
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if deleted != 1 {
		t.Fatalf("swept %d invites, want 1", deleted)
	}
	if w.exists(t, "pair_invites", stale.Id) {
		// Marking it expired and keeping it was the old behaviour, and it left
		// a permanent record of who invited whom for an invite nobody used.
		t.Error("an expired invite is still there")
	}
}

func TestTheSweepLeavesLiveInvitesAlone(t *testing.T) {
	w := newLifeWorld(t)

	deleted, err := pairs.DeleteExpiredInvites(w.app, types.NowDateTime())
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if deleted != 0 {
		t.Fatalf("swept %d invites, want 0", deleted)
	}
	if !w.exists(t, "pair_invites", w.invite.Id) {
		t.Error("the seeded invite has not expired yet and was deleted anyway")
	}
}

// An accepted invite is not "unused", and the connection it produced is the
// proof. Its expiry passes like any other, so without the status check the sweep
// would eventually take every invite ever accepted.
func TestTheSweepLeavesAcceptedInvitesAlone(t *testing.T) {
	w := newLifeWorld(t)
	accepted := w.newInviteAt(t, "USED01", "accepted", w.hoursAgo(48))

	if _, err := pairs.DeleteExpiredInvites(w.app, types.NowDateTime()); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if !w.exists(t, "pair_invites", accepted.Id) {
		t.Error("an accepted invite was swept")
	}
}

// Nothing this server issues has an empty expiry, so such a row can only have
// been made deliberately from the dashboard. An empty date sorts before every
// real one, which is exactly how a naive filter deletes it.
func TestTheSweepLeavesInvitesWithNoExpiryAlone(t *testing.T) {
	w := newLifeWorld(t)
	forever := w.newInviteAt(t, "FOREVR", "pending", "")

	if _, err := pairs.DeleteExpiredInvites(w.app, types.NowDateTime()); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if !w.exists(t, "pair_invites", forever.Id) {
		t.Error("an invite with no expiry was swept")
	}
}

// Up to fifteen minutes can pass between an invite expiring and the sweep
// noticing. Somebody typing the code in has just demonstrated that it is past
// its time, so it goes then and there.
func TestAcceptingAnExpiredCodeDeletesIt(t *testing.T) {
	w := newLifeWorld(t)
	stale := w.newInviteAt(t, "STALE2", "pending", w.hoursAgo(1))

	status, body := w.do(t, "POST", "/api/peard/pairs/accept", w.bobTok, `{"code":"STALE2"}`)
	if status != 400 {
		t.Fatalf("accept expired: %d %s", status, body)
	}
	if w.exists(t, "pair_invites", stale.Id) {
		t.Error("the expired invite survived being presented")
	}
}

// A code that has expired is now simply absent, so the not-found path is what
// somebody typing a day-old code actually hits. It has to say something they can
// act on rather than "not found".
func TestAnUnknownCodeSaysWhatMightHaveHappened(t *testing.T) {
	w := newLifeWorld(t)

	status, body := w.do(t, "POST", "/api/peard/pairs/accept", w.bobTok, `{"code":"NOPE99"}`)
	if status != 404 {
		t.Fatalf("accept unknown: %d %s", status, body)
	}
	for _, want := range []string{"expired", "already been used"} {
		if !strings.Contains(body, want) {
			t.Errorf("message %q does not mention %q", body, want)
		}
	}
}

// MARK: helpers

// newInviteAt makes an invite with an expiry of the caller's choosing, which is
// the one thing the seeded invite cannot vary.
func (w *lifeWorld) newInviteAt(t *testing.T, code, status, expires string) *core.Record {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("pair_invites")
	if err != nil {
		t.Fatalf("pair_invites collection: %v", err)
	}
	r := core.NewRecord(col)
	r.Set("code", code)
	r.Set("inviter", w.alice.Id)
	r.Set("status", status)
	r.Set("expires", expires)
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save invite %s: %v", code, err)
	}
	return r
}

func (w *lifeWorld) hoursAgo(hours int) string {
	return time.Now().Add(-time.Duration(hours) * time.Hour).UTC().Format(types.DefaultDateLayout)
}
