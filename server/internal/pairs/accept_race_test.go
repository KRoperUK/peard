package pairs_test

import (
	"net/http"
	"sync"
	"testing"

	"github.com/pocketbase/dbx"
)

// An invite code is a single-use bearer credential. Two people racing the same
// code — or one person's client retrying before the first request answered —
// must not both succeed: the invite is claimed inside the transaction that adds
// the member, so the first commit flips it to accepted and the second re-reads
// it, no longer finds status = 'pending', and is turned away. Without that the
// out-of-transaction check both callers passed would let both commit.

// countMembers is the invariant under test: how many memberships a pair holds.
func (w *lifeWorld) countMembers(t *testing.T, pairID string) int {
	t.Helper()
	n, err := w.app.CountRecords("pair_members", dbx.HashExp{"pair": pairID})
	if err != nil {
		t.Fatalf("count members of %s: %v", pairID, err)
	}
	return int(n)
}

// A group invite accepted twice adds the joiner once. The second accept of the
// now-spent code is refused rather than adding a duplicate membership.
func TestAGroupInviteCannotBeAcceptedTwice(t *testing.T) {
	w := newLifeWorld(t)
	carol, carolTok := w.newUser(t, "carol@example.com", "Carol Clark")
	_ = carol

	before := w.countMembers(t, w.flatmates.Id)

	status, body := w.do(t, http.MethodPost, "/api/peard/pairs/accept", carolTok, `{"code":"ABCDEF"}`)
	if status != http.StatusOK {
		t.Fatalf("first accept: %d %s", status, body)
	}
	if got := w.countMembers(t, w.flatmates.Id); got != before+1 {
		t.Fatalf("members after first accept = %d, want %d", got, before+1)
	}

	// The code is spent now; presenting it again must not add carol a second
	// time, and must not 500.
	status, body = w.do(t, http.MethodPost, "/api/peard/pairs/accept", carolTok, `{"code":"ABCDEF"}`)
	if status != http.StatusNotFound {
		t.Fatalf("second accept: %d %s, want 404 (invite spent)", status, body)
	}
	if got := w.countMembers(t, w.flatmates.Id); got != before+1 {
		t.Errorf("members after second accept = %d, want %d — the spent code added a duplicate", got, before+1)
	}
}

// A 1:1 invite accepted concurrently makes exactly one connection. Several
// requests fire the same code at once; the transaction-scoped claim means only
// the one that commits first creates a pair, and the rest are refused.
func TestConcurrentAcceptsOfAOneToOneInviteMakeOnePair(t *testing.T) {
	w := newLifeWorld(t)
	// A fresh pending 1:1 invite from bob (no `pair`, so acceptance mints a new
	// connection) that carol will race.
	w.newInviteAt(t, "RACE01", "pending", w.hoursAgo(-24)) // expires 24h from now
	bobInvite, err := w.app.FindFirstRecordByFilter("pair_invites", "code = 'RACE01'", nil)
	if err != nil {
		t.Fatalf("find RACE01: %v", err)
	}
	bobInvite.Set("inviter", w.bob.Id)
	if err := w.app.Save(bobInvite); err != nil {
		t.Fatalf("set inviter: %v", err)
	}

	carol, carolTok := w.newUser(t, "carol@example.com", "Carol Clark")

	pairsBefore, err := w.app.CountRecords("pairs")
	if err != nil {
		t.Fatalf("count pairs: %v", err)
	}

	const racers = 5
	var wg sync.WaitGroup
	results := make([]int, racers)
	bodies := make([]string, racers)
	for i := 0; i < racers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i], bodies[i] = w.do(t, http.MethodPost, "/api/peard/pairs/accept", carolTok, `{"code":"RACE01"}`)
		}(i)
	}
	wg.Wait()

	okCount := 0
	for i, status := range results {
		switch status {
		case http.StatusOK:
			okCount++
		case http.StatusNotFound, http.StatusBadRequest, http.StatusInternalServerError:
			// A loser of the race. 500 is tolerated only because SQLite can
			// surface a write conflict as one; what matters is it did not
			// create a second connection.
		default:
			t.Errorf("racer %d: unexpected status %d %s", i, status, bodies[i])
		}
	}
	if okCount == 0 {
		t.Fatalf("no racer succeeded; bodies=%v", bodies)
	}

	// The invariant: exactly one new connection, and carol is in exactly one.
	pairsAfter, err := w.app.CountRecords("pairs")
	if err != nil {
		t.Fatalf("count pairs after: %v", err)
	}
	if pairsAfter-pairsBefore != 1 {
		t.Errorf("new pairs = %d, want 1 — the code was accepted more than once", pairsAfter-pairsBefore)
	}
	carolMemberships, err := w.app.CountRecords("pair_members", dbx.HashExp{"user": carol.Id})
	if err != nil {
		t.Fatalf("count carol memberships: %v", err)
	}
	if carolMemberships != 1 {
		t.Errorf("carol's memberships = %d, want 1", carolMemberships)
	}
}
