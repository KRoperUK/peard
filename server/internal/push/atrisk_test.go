package push

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/sideshow/apns2"
)

// waterOn logs `ml` of water for `user` in `pair` at the given absolute UTC
// instant, backdating happened_at the way the recap tests do (the record API
// ignores writes to the autodate `created`, so the day is set in SQL).
func waterOn(t *testing.T, app core.App, pair, user *core.Record, ml int, at time.Time) {
	t.Helper()
	r := newRecord(t, app, "posts", map[string]any{
		"pair": pair.Id, "author": user.Id, "type": "event", "event_kind": "water", "amount": ml,
	})
	stamp := at.UTC().Format("2006-01-02 15:04:05.000Z")
	if _, err := app.NonconcurrentDB().
		NewQuery("UPDATE {{posts}} SET [[created]] = {:t}, [[happened_at]] = {:t} WHERE [[id]] = {:id}").
		Bind(map[string]any{"t": stamp, "id": r.Id}).Execute(); err != nil {
		t.Fatalf("backdate water: %v", err)
	}
}

func TestAtRiskDueOnlyInTheReminderHour(t *testing.T) {
	loc := time.UTC
	cases := []struct {
		hour int
		want bool
	}{
		{20, false},
		{21, true},
		{22, false},
		{0, false},
	}
	for _, c := range cases {
		now := time.Date(2026, 8, 5, c.hour, 30, 0, 0, loc)
		if got := atRiskDue(now, loc); got != c.want {
			t.Errorf("atRiskDue at %02d:30 = %v, want %v", c.hour, got, c.want)
		}
	}
}

// The reminder is for exactly the person who met their goal yesterday but is
// short today — a live streak with something to lose.
func TestStreakAtRiskIsYesterdayMetTodayShort(t *testing.T) {
	app := newMediaApp(t)
	ada := newUser(t, app, "ada@example.com")
	pair := newRecord(t, app, "pairs", map[string]any{})
	newRecord(t, app, "pair_members", map[string]any{"pair": pair.Id, "user": ada.Id, "role": "member"})

	loc := time.UTC
	today := time.Now().UTC()
	yesterday := today.AddDate(0, 0, -1)

	// Met yesterday, nothing today yet.
	waterOn(t, app, pair, ada, 2000, time.Date(yesterday.Year(), yesterday.Month(), yesterday.Day(), 12, 0, 0, 0, loc))

	if !streakAtRisk(app, pair.Id, ada.Id, loc, 2000) {
		t.Fatal("yesterday met, today empty: want at risk")
	}

	// Now top up today past the goal — no longer at risk.
	waterOn(t, app, pair, ada, 2000, time.Date(today.Year(), today.Month(), today.Day(), 9, 0, 0, 0, loc))
	if streakAtRisk(app, pair.Id, ada.Id, loc, 2000) {
		t.Fatal("goal already met today: want NOT at risk")
	}
}

// No streak to lose — yesterday was short — is not at risk, however little is
// logged today.
func TestNoStreakYesterdayIsNotAtRisk(t *testing.T) {
	app := newMediaApp(t)
	ada := newUser(t, app, "ada@example.com")
	pair := newRecord(t, app, "pairs", map[string]any{})
	newRecord(t, app, "pair_members", map[string]any{"pair": pair.Id, "user": ada.Id, "role": "member"})

	loc := time.UTC
	yesterday := time.Now().UTC().AddDate(0, 0, -1)
	waterOn(t, app, pair, ada, 500, time.Date(yesterday.Year(), yesterday.Month(), yesterday.Day(), 12, 0, 0, 0, loc)) // short

	if streakAtRisk(app, pair.Id, ada.Id, loc, 2000) {
		t.Fatal("yesterday was short: no streak, so not at risk")
	}
}

// End to end: at the reminder hour, only the member with a streak at risk is
// pushed — not the one already at goal, not a muted member.
func TestAtRiskRemindsOnlyTheMemberWithAStreakToLose(t *testing.T) {
	app := newMediaApp(t)
	var mu sync.Mutex
	var sentTo []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		sentTo = append(sentTo, strings.TrimPrefix(r.URL.Path, "/3/device/"))
		mu.Unlock()
	}))
	t.Cleanup(srv.Close)
	previous := n
	n = &notifier{client: &apns2.Client{Host: srv.URL, HTTPClient: srv.Client()}, bundleID: "com.peard.test"}
	t.Cleanup(func() { n = previous })

	ada := newUser(t, app, "ada@example.com") // at risk: met yesterday, short today
	bo := newUser(t, app, "bo@example.com")   // safe: already at goal today
	cat := newUser(t, app, "cat@example.com") // at risk but muted
	pair := newRecord(t, app, "pairs", map[string]any{})
	newRecord(t, app, "pair_members", map[string]any{"pair": pair.Id, "user": ada.Id, "role": "member", "water_recommended": 2000})
	newRecord(t, app, "pair_members", map[string]any{"pair": pair.Id, "user": bo.Id, "role": "member", "water_recommended": 2000})
	newRecord(t, app, "pair_members", map[string]any{"pair": pair.Id, "user": cat.Id, "role": "member", "water_recommended": 2000, "muted": true})
	newRecord(t, app, "devices", map[string]any{"user": ada.Id, "platform": "ios", "push_token": "ada-device"})
	newRecord(t, app, "devices", map[string]any{"user": bo.Id, "platform": "ios", "push_token": "bo-device"})
	newRecord(t, app, "devices", map[string]any{"user": cat.Id, "platform": "ios", "push_token": "cat-device"})

	today := time.Now().UTC()
	yesterday := today.AddDate(0, 0, -1)
	yNoon := func(u *core.Record, ml int) {
		waterOn(t, app, pair, u, ml, time.Date(yesterday.Year(), yesterday.Month(), yesterday.Day(), 12, 0, 0, 0, time.UTC))
	}
	tMorning := func(u *core.Record, ml int) {
		waterOn(t, app, pair, u, ml, time.Date(today.Year(), today.Month(), today.Day(), 9, 0, 0, 0, time.UTC))
	}
	yNoon(ada, 2000) // ada met yesterday, nothing today
	yNoon(bo, 2000)
	tMorning(bo, 2000) // bo already at goal today
	yNoon(cat, 2000)   // cat at risk but muted

	// 21:00 UTC — the reminder hour for a UTC device (no stored zone).
	now := time.Date(today.Year(), today.Month(), today.Day(), 21, 0, 0, 0, time.UTC)
	sendAtRiskRemindersAt(app, now)

	mu.Lock()
	defer mu.Unlock()
	if len(sentTo) != 1 || sentTo[0] != "ada-device" {
		t.Fatalf("at-risk sent to %v, want only ada-device", sentTo)
	}
}

// Outside the reminder hour, nobody is pushed however at-risk they are.
func TestAtRiskIsSilentOutsideTheReminderHour(t *testing.T) {
	app := newMediaApp(t)
	var mu sync.Mutex
	var sent int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		sent++
		mu.Unlock()
	}))
	t.Cleanup(srv.Close)
	previous := n
	n = &notifier{client: &apns2.Client{Host: srv.URL, HTTPClient: srv.Client()}, bundleID: "com.peard.test"}
	t.Cleanup(func() { n = previous })

	ada := newUser(t, app, "ada@example.com")
	pair := newRecord(t, app, "pairs", map[string]any{})
	newRecord(t, app, "pair_members", map[string]any{"pair": pair.Id, "user": ada.Id, "role": "member", "water_recommended": 2000})
	newRecord(t, app, "devices", map[string]any{"user": ada.Id, "platform": "ios", "push_token": "ada-device"})

	today := time.Now().UTC()
	yesterday := today.AddDate(0, 0, -1)
	waterOn(t, app, pair, ada, 2000, time.Date(yesterday.Year(), yesterday.Month(), yesterday.Day(), 12, 0, 0, 0, time.UTC))

	// 15:00 UTC — nowhere near the 21:00 reminder hour.
	now := time.Date(today.Year(), today.Month(), today.Day(), 15, 0, 0, 0, time.UTC)
	sendAtRiskRemindersAt(app, now)

	mu.Lock()
	defer mu.Unlock()
	if sent != 0 {
		t.Fatalf("at-risk sent %d pushes at 15:00, want 0", sent)
	}
}
