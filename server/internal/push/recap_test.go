package push

import (
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
	"github.com/sideshow/apns2"

	_ "peard/migrations"
)

func newRecapTestApp(t *testing.T) *tests.TestApp {
	t.Helper()

	dir, err := os.MkdirTemp("", "peard-recap-test-*")
	if err != nil {
		t.Fatalf("temp dir: %v", err)
	}
	app, err := tests.NewTestApp(dir)
	if err != nil {
		os.RemoveAll(dir)
		t.Fatalf("new test app: %v", err)
	}
	t.Cleanup(func() {
		app.Cleanup()
		os.RemoveAll(dir)
	})
	return app
}

func newUnsavedPost(t *testing.T, app core.App, kind string) *core.Record {
	t.Helper()
	col, err := app.FindCollectionByNameOrId("posts")
	if err != nil {
		t.Fatalf("find posts collection: %v", err)
	}
	post := core.NewRecord(col)
	post.Set("type", "event")
	post.Set("event_kind", kind)
	return post
}

func TestRecapBodyOrdersByFrequency(t *testing.T) {
	app := newRecapTestApp(t)

	posts := []*core.Record{
		newUnsavedPost(t, app, "beer"),
		newUnsavedPost(t, app, "loo"),
		newUnsavedPost(t, app, "beer"),
		newUnsavedPost(t, app, "coffee"),
		newUnsavedPost(t, app, "beer"),
	}

	got := recapBody(app, "", posts)
	// Both singles keep insertion order (loo logged before coffee) once the
	// triple beer sorts to the front — sort.SliceStable's whole job.
	want := "🍺 3, 💩 1, ☕ 1"
	if got != want {
		t.Fatalf("recapBody() = %q, want %q", got, want)
	}
}

func TestRecapBodyEmptyWithNoEventKinds(t *testing.T) {
	app := newRecapTestApp(t)

	post := newUnsavedPost(t, app, "")
	if got := recapBody(app, "", []*core.Record{post}); got != "" {
		t.Fatalf("recapBody() = %q, want empty", got)
	}
}

func TestRecapBodyCapsToTopKinds(t *testing.T) {
	app := newRecapTestApp(t)

	posts := []*core.Record{
		newUnsavedPost(t, app, "beer"),
		newUnsavedPost(t, app, "loo"),
		newUnsavedPost(t, app, "coffee"),
		newUnsavedPost(t, app, "dog_walk"),
		newUnsavedPost(t, app, "chores"),
	}

	got := recapBody(app, "", posts)
	count := 1
	for _, r := range got {
		if r == ',' {
			count++
		}
	}
	if count != maxRecapKinds {
		t.Fatalf("recapBody() listed %d kinds, want %d: %q", count, maxRecapKinds, got)
	}
}

func TestStartOfWeekPinsToMonday(t *testing.T) {
	cases := []struct {
		name string
		now  time.Time
		want time.Time
	}{
		{
			name: "Wednesday mid-week",
			now:  time.Date(2026, 8, 5, 14, 30, 0, 0, time.UTC), // Wednesday
			want: time.Date(2026, 8, 3, 0, 0, 0, 0, time.UTC),   // preceding Monday
		},
		{
			name: "Sunday evening, the recap's own send time",
			now:  time.Date(2026, 8, 9, 18, 0, 0, 0, time.UTC), // Sunday
			want: time.Date(2026, 8, 3, 0, 0, 0, 0, time.UTC),  // same week's Monday
		},
		{
			name: "Monday itself, just after midnight",
			now:  time.Date(2026, 8, 3, 0, 30, 0, 0, time.UTC),
			want: time.Date(2026, 8, 3, 0, 0, 0, 0, time.UTC),
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := startOfWeek(c.now); !got.Equal(c.want) {
				t.Fatalf("startOfWeek(%v) = %v, want %v", c.now, got, c.want)
			}
		})
	}
}

// A connection somebody has muted must stay silent for them on Sunday too: the
// recap is a notification from that connection like any other.
func TestTheRecapSkipsAMemberWhoMutedTheConnection(t *testing.T) {
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

	ada := newUser(t, app, "ada@example.com")
	bo := newUser(t, app, "bo@example.com")
	pair := newRecord(t, app, "pairs", map[string]any{"name": "Flatmates"})
	newRecord(t, app, "pair_members", map[string]any{"pair": pair.Id, "user": ada.Id, "role": "member"})
	newRecord(t, app, "pair_members", map[string]any{"pair": pair.Id, "user": bo.Id, "role": "member", "muted": true})
	newRecord(t, app, "devices", map[string]any{"user": ada.Id, "platform": "ios", "push_token": "ada-device"})
	newRecord(t, app, "devices", map[string]any{"user": bo.Id, "platform": "ios", "push_token": "bo-device"})
	sunday := time.Date(2026, 8, 9, 18, 0, 0, 0, time.UTC)
	newRecord(t, app, "posts", map[string]any{
		"pair": pair.Id, "author": ada.Id, "type": "event", "event_kind": "beer", "happened_at": sunday.Add(-time.Hour),
	})

	sendWeeklyRecapsAt(app, sunday)

	mu.Lock()
	defer mu.Unlock()
	if len(sentTo) != 1 || sentTo[0] != "ada-device" {
		t.Fatalf("recap sent to %v, want only ada-device", sentTo)
	}
}

// The recap runs every hour and goes to each device in the hour its own clock
// reads Sunday 18:00. Walking every hour of a week has to find that hour once
// and only once, in every kind of zone: whole-hour, half-hour and three-quarter
// offsets, both sides of UTC, and weeks with a clock change in them.
func TestTheRecapIsDueOnceAWeekInEveryZone(t *testing.T) {
	weeks := map[string]time.Time{
		"an ordinary week":                      time.Date(2026, 8, 3, 0, 0, 0, 0, time.UTC),
		"Europe's clocks go forward (29 Mar)":   time.Date(2026, 3, 23, 0, 0, 0, 0, time.UTC),
		"America's clocks go back (1 Nov)":      time.Date(2026, 10, 26, 0, 0, 0, 0, time.UTC),
		"Australia's clocks go forward (4 Oct)": time.Date(2026, 9, 28, 0, 0, 0, 0, time.UTC),
	}
	zones := []string{
		"UTC", "Europe/London", "America/New_York", "America/Los_Angeles",
		"Asia/Tokyo", "Asia/Kolkata", "Asia/Kathmandu", "Australia/Sydney",
		"Pacific/Auckland", "Pacific/Chatham", "America/St_Johns", "Pacific/Kiritimati",
	}
	for week, monday := range weeks {
		for _, name := range zones {
			loc, err := time.LoadLocation(name)
			if err != nil {
				t.Fatalf("load %s: %v", name, err)
			}
			// Seven days from the Wednesday noon, UTC: every zone's Sunday
			// evening falls between Saturday morning and Monday morning UTC,
			// well inside the walk, so each should be seen exactly once.
			var due []time.Time
			from := monday.Add(60 * time.Hour)
			for hour := from; hour.Before(from.Add(7 * 24 * time.Hour)); hour = hour.Add(time.Hour) {
				if recapDue(hour, loc) {
					due = append(due, hour)
				}
			}
			if len(due) != 1 {
				t.Errorf("%s, %s: due at %v, want exactly one hour", week, name, due)
				continue
			}
			local := due[0].In(loc)
			if local.Weekday() != time.Sunday || local.Hour() != 18 {
				t.Errorf("%s, %s: due at %v local, want Sunday in the 18:00 hour", week, name, local)
			}
		}
	}
}

// Across a clock change the recap follows the local clock, not a fixed UTC
// hour: on the Sunday the UK moves to BST, 18:00 in London is 17:00 UTC.
func TestTheRecapFollowsTheClockChange(t *testing.T) {
	london, _ := time.LoadLocation("Europe/London")

	if !recapDue(time.Date(2026, 3, 29, 17, 0, 0, 0, time.UTC), london) {
		t.Error("not due at 17:00 UTC on the first day of BST, which is 18:00 in London")
	}
	if recapDue(time.Date(2026, 3, 29, 18, 0, 0, 0, time.UTC), london) {
		t.Error("due at 18:00 UTC on the first day of BST, which is 19:00 in London")
	}
	// The week it covers still starts at the Monday's midnight in London, which
	// was before the change and so midnight UTC too.
	week := startOfWeek(time.Date(2026, 3, 29, 17, 0, 0, 0, time.UTC).In(london))
	if want := time.Date(2026, 3, 23, 0, 0, 0, 0, time.UTC); !week.Equal(want) {
		t.Errorf("week starts %v, want %v", week.UTC(), want)
	}
}

// A device that never said where it is — a build from before the field, or a
// value that is not a zone — gets the recap at 18:00 UTC, as every device did
// before.
func TestAnUnknownZoneFallsBackToUTC(t *testing.T) {
	for _, stored := range []string{"", "Mars/Olympus_Mons"} {
		loc := deviceZone(stored)
		if loc != time.UTC {
			t.Errorf("%q: zone %v, want UTC", stored, loc)
		}
	}
	if !recapDue(time.Date(2026, 8, 9, 18, 0, 0, 0, time.UTC), deviceZone("")) {
		t.Error("an unknown zone is not due at 18:00 UTC on Sunday")
	}
}

// The whole run, for devices in three places. At 09:00 UTC on Sunday it is
// 18:00 in Tokyo, so only the Tokyo device hears anything; at 18:00 UTC the
// device with no zone does; London had its turn an hour before.
//
// The one moment was logged at 00:30 on Monday in Tokyo, which is 15:30 on
// Sunday in UTC — last week, by a UTC calendar. The Tokyo device getting a
// recap at all shows the week was counted from Tokyo's Monday.
func TestTheRecapReachesEachDeviceOnItsOwnSundayEvening(t *testing.T) {
	app := newMediaApp(t)
	apns := installFakeAPNs(t, nil)

	ada := newUser(t, app, "ada@example.com")
	bo := newUser(t, app, "bo@example.com")
	cy := newUser(t, app, "cy@example.com")
	pair := newRecord(t, app, "pairs", map[string]any{"name": "Flatmates"})
	for _, u := range []*core.Record{ada, bo, cy} {
		newRecord(t, app, "pair_members", map[string]any{"pair": pair.Id, "user": u.Id, "role": "member"})
	}
	newRecord(t, app, "devices", map[string]any{"user": ada.Id, "platform": "ios", "push_token": "tokyo-device", "time_zone": "Asia/Tokyo"})
	newRecord(t, app, "devices", map[string]any{"user": bo.Id, "platform": "ios", "push_token": "london-device", "time_zone": "Europe/London"})
	newRecord(t, app, "devices", map[string]any{"user": cy.Id, "platform": "ios", "push_token": "somewhere-device"})
	newRecord(t, app, "posts", map[string]any{
		"pair": pair.Id, "author": ada.Id, "type": "event", "event_kind": "beer",
		"happened_at": time.Date(2026, 8, 2, 15, 30, 0, 0, time.UTC),
	})

	for _, tc := range []struct {
		at   time.Time
		want []string
	}{
		{time.Date(2026, 8, 9, 9, 0, 0, 0, time.UTC), []string{"tokyo-device"}},
		{time.Date(2026, 8, 9, 12, 0, 0, 0, time.UTC), []string{"tokyo-device"}},
		// London's hour, but by London's calendar the moment was last week.
		{time.Date(2026, 8, 9, 17, 0, 0, 0, time.UTC), []string{"tokyo-device"}},
		{time.Date(2026, 8, 9, 18, 0, 0, 0, time.UTC), []string{"tokyo-device"}},
	} {
		sendWeeklyRecapsAt(app, tc.at)
		if got := apns.sentTo(); !slices.Equal(got, tc.want) {
			t.Fatalf("after the %s run: sent to %v, want %v", tc.at.Format("15:04 UTC"), got, tc.want)
		}
	}

	// And with a moment inside everybody's week, the other two hear on their
	// own Sunday evenings.
	newRecord(t, app, "posts", map[string]any{
		"pair": pair.Id, "author": ada.Id, "type": "event", "event_kind": "beer",
		"happened_at": time.Date(2026, 8, 5, 12, 0, 0, 0, time.UTC),
	})
	sendWeeklyRecapsAt(app, time.Date(2026, 8, 9, 17, 0, 0, 0, time.UTC))
	sendWeeklyRecapsAt(app, time.Date(2026, 8, 9, 18, 0, 0, 0, time.UTC))
	want := []string{"tokyo-device", "london-device", "somewhere-device"}
	if got := apns.sentTo(); !slices.Equal(got, want) {
		t.Fatalf("sent to %v, want %v", got, want)
	}
}

// The device row is written by the app, so the field only takes something
// shaped like a zone name — and nothing, for the rows older builds write.
func TestADevicesZoneMustLookLikeOne(t *testing.T) {
	app := newMediaApp(t)
	ada := newUser(t, app, "ada@example.com")
	col, err := app.FindCollectionByNameOrId("devices")
	if err != nil {
		t.Fatalf("devices collection: %v", err)
	}

	for i, tc := range []struct {
		zone string
		ok   bool
	}{
		{"", true},
		{"America/Argentina/Buenos_Aires", true},
		{"Etc/GMT+5", true},
		{"../../etc/passwd", false},
		{"Europe/London; DROP", false},
		{strings.Repeat("A", 65), false},
	} {
		d := core.NewRecord(col)
		d.Set("user", ada.Id)
		d.Set("platform", "ios")
		d.Set("push_token", "device-"+strconv.Itoa(i))
		d.Set("time_zone", tc.zone)
		if err := app.Save(d); (err == nil) != tc.ok {
			t.Errorf("%q: save error %v, want ok=%v", tc.zone, err, tc.ok)
		}
	}
}
