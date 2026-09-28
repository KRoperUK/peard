package push

import (
	"net/http"
	"net/http/httptest"
	"os"
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
	weekStart := startOfWeek(time.Now())
	newRecord(t, app, "posts", map[string]any{
		"pair": pair.Id, "author": ada.Id, "type": "event", "event_kind": "beer", "happened_at": time.Now(),
	})

	sendRecapFor(app, pair, weekStart)

	mu.Lock()
	defer mu.Unlock()
	if len(sentTo) != 1 || sentTo[0] != "ada-device" {
		t.Fatalf("recap sent to %v, want only ada-device", sentTo)
	}
}
