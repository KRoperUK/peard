package zone_test

import (
	"os"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"peard/internal/zone"
	_ "peard/migrations"
)

func newApp(t *testing.T) *tests.TestApp {
	t.Helper()
	dir, err := os.MkdirTemp("", "peard-zone-test-*")
	if err != nil {
		t.Fatal(err)
	}
	app, err := tests.NewTestApp(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { app.Cleanup(); os.RemoveAll(dir) })
	return app
}

func save(t *testing.T, app core.App, collection string, fields map[string]any) *core.Record {
	t.Helper()
	col, err := app.FindCollectionByNameOrId(collection)
	if err != nil {
		t.Fatal(err)
	}
	r := core.NewRecord(col)
	for k, v := range fields {
		r.Set(k, v)
	}
	if collection == "users" {
		r.SetPassword("Password123!")
	}
	if err := app.Save(r); err != nil {
		t.Fatalf("save %s: %v", collection, err)
	}
	return r
}

// The latest device wins: it is rewritten each session, so it is where the
// person is now.
func TestForUserIsTheLatestDevicesZone(t *testing.T) {
	app := newApp(t)
	user := save(t, app, "users", map[string]any{"email": "ada@example.com"})
	save(t, app, "devices", map[string]any{"user": user.Id, "platform": "ios", "push_token": "old", "time_zone": "America/New_York"})
	time.Sleep(5 * time.Millisecond)
	save(t, app, "devices", map[string]any{"user": user.Id, "platform": "ios", "push_token": "new", "time_zone": "Asia/Tokyo"})

	if got := zone.ForUser(app, user.Id).String(); got != "Asia/Tokyo" {
		t.Fatalf("zone = %s, want Asia/Tokyo", got)
	}
}

func TestForUserFallsBackToUTC(t *testing.T) {
	app := newApp(t)
	user := save(t, app, "users", map[string]any{"email": "bo@example.com"})
	if got := zone.ForUser(app, user.Id); got != time.UTC {
		t.Fatalf("no device: zone = %s, want UTC", got)
	}
	save(t, app, "devices", map[string]any{"user": user.Id, "platform": "ios", "push_token": "t"})
	if got := zone.ForUser(app, user.Id); got != time.UTC {
		t.Fatalf("device without a zone: zone = %s, want UTC", got)
	}
	if got := zone.ForUser(app, ""); got != time.UTC {
		t.Fatalf("no user: zone = %s, want UTC", got)
	}
}
