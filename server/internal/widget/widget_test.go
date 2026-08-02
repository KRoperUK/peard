// The widget feed's unread count.
//
// External to `widget` so the real schema can come from blank-importing
// `peard/migrations`, which imports this package.
//
// The widget package had no server tests before this. These cover the one thing
// most likely to break silently — the feed is fetched by an extension with no
// screen to report an error on, so a wrong or missing field shows up as a widget
// that quietly says the wrong thing rather than as a failure anybody sees.
package widget_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
	"github.com/pocketbase/pocketbase/tools/types"

	"peard/internal/widget"

	_ "peard/migrations"
)

type feedWorld struct {
	app *tests.TestApp
	mux http.Handler

	alice, bob *core.Record
	pair       *core.Record
	token      string
}

func newFeedWorld(t *testing.T) *feedWorld {
	t.Helper()

	dir, err := os.MkdirTemp("", "peard-widget-test-*")
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

	widget.Register(app)

	w := &feedWorld{app: app}
	w.alice = w.newUser(t, "alice@example.com", "Alice")
	w.bob = w.newUser(t, "bob@example.com", "Bob")
	w.pair = w.newRecord(t, "pairs", map[string]any{"name": "Flatmates"})
	w.newRecord(t, "pair_members", map[string]any{"pair": w.pair.Id, "user": w.alice.Id, "role": "owner"})
	w.newRecord(t, "pair_members", map[string]any{"pair": w.pair.Id, "user": w.bob.Id, "role": "member"})
	w.token = "widget-token-for-alice"
	w.newRecord(t, "widget_tokens", map[string]any{"user": w.alice.Id, "token": w.token})

	router, err := apis.NewRouter(app)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}
	event := new(core.ServeEvent)
	event.App = app
	event.Router = router
	if err := app.OnServe().Trigger(event, func(e *core.ServeEvent) error {
		mux, err := e.Router.BuildMux()
		if err != nil {
			return err
		}
		w.mux = mux
		return nil
	}); err != nil {
		t.Fatalf("build mux: %v", err)
	}
	return w
}

func (w *feedWorld) newUser(t *testing.T, email, name string) *core.Record {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("users collection: %v", err)
	}
	r := core.NewRecord(col)
	r.SetEmail(email)
	r.SetVerified(true)
	r.SetPassword("Password123!")
	r.Set("display_name", name)
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save user: %v", err)
	}
	return r
}

func (w *feedWorld) newRecord(t *testing.T, collection string, fields map[string]any) *core.Record {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId(collection)
	if err != nil {
		t.Fatalf("%s collection: %v", collection, err)
	}
	r := core.NewRecord(col)
	for k, v := range fields {
		r.Set(k, v)
	}
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save %s: %v", collection, err)
	}
	return r
}

func (w *feedWorld) newPost(t *testing.T, author *core.Record, note string) *core.Record {
	t.Helper()
	return w.newRecord(t, "posts", map[string]any{
		"pair": w.pair.Id, "author": author.Id,
		"type": "event", "event_kind": "beer", "note": note,
	})
}

// unread fetches the feed and returns its `unread`, failing on anything that is
// not a clean 200 — so a broken route can never be read as "nothing new".
func (w *feedWorld) unread(t *testing.T) int {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/peard/widget/feed?token="+w.token, nil)
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("feed: got %d, body %s", rec.Code, rec.Body.String())
	}
	var parsed struct {
		State  string `json:"state"`
		Unread int    `json:"unread"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &parsed); err != nil {
		t.Fatalf("decode feed: %v (body %s)", err, rec.Body.String())
	}
	return parsed.Unread
}

func TestFeedReportsSomebodyElsesMomentAsUnread(t *testing.T) {
	w := newFeedWorld(t)
	w.newPost(t, w.bob, "from Bob")

	if got := w.unread(t); got != 1 {
		t.Fatalf("got %d, want 1", got)
	}
}

// The widget is Alice's; her own moments are not news to her, exactly as in the
// app's rail and the push badge.
func TestFeedDoesNotCountYourOwnMoments(t *testing.T) {
	w := newFeedWorld(t)
	w.newPost(t, w.alice, "mine")

	if got := w.unread(t); got != 0 {
		t.Fatalf("got %d, want 0", got)
	}
}

func TestFeedUnreadClearsOnceSeen(t *testing.T) {
	w := newFeedWorld(t)
	w.newPost(t, w.bob, "from Bob")

	membership, err := w.app.FindFirstRecordByFilter("pair_members",
		"pair = {:pair} && user = {:user}",
		map[string]any{"pair": w.pair.Id, "user": w.alice.Id})
	if err != nil {
		t.Fatalf("membership: %v", err)
	}
	membership.Set("last_seen_at", types.NowDateTime().Add(time.Second))
	if err := w.app.Save(membership); err != nil {
		t.Fatalf("stamp: %v", err)
	}

	if got := w.unread(t); got != 0 {
		t.Fatalf("got %d, want 0", got)
	}
}

// connections issues GET /api/peard/widget/connections and returns the decoded
// list, so the two tests below differ only in the query they ask.
func (w *feedWorld) connections(t *testing.T, query string) []map[string]any {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/peard/widget/connections?token="+w.token+query, nil)
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("connections: got %d, body %s", rec.Code, rec.Body.String())
	}
	var parsed struct {
		Connections []map[string]any `json:"connections"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &parsed); err != nil {
		t.Fatalf("decode connections: %v (body %s)", err, rec.Body.String())
	}
	return parsed.Connections
}

// `?moments=1` exists so the Shortcuts picker can offer every connection's
// catalogue at once. It used to fetch a whole feed per connection — tallies,
// latest post, unread count — to read one list out of each.
func TestConnectionsCarryTheirMomentsWhenAsked(t *testing.T) {
	w := newFeedWorld(t)
	w.newRecord(t, "moment_kinds", map[string]any{
		"pair": w.pair.Id, "slug": "dog_walk", "emoji": "🐕", "label": "Dog walk", "created_by": w.alice.Id,
	})

	connections := w.connections(t, "&moments=1")
	if len(connections) != 1 {
		t.Fatalf("got %d connections, want 1", len(connections))
	}

	moments, ok := connections[0]["moments"].([]any)
	if !ok {
		t.Fatalf("expected moments on the connection, got %v", connections[0])
	}
	var labels []string
	for _, moment := range moments {
		labels = append(labels, moment.(map[string]any)["label"].(string))
	}
	// The built-ins are there too — every connection can log those — so this
	// asserts the custom one arrived rather than the exact list.
	if !slices.Contains(labels, "Dog walk") {
		t.Fatalf("expected the published moment in %v", labels)
	}
	if !slices.Contains(labels, "Beer") {
		t.Fatalf("expected the built-ins in %v", labels)
	}
}

// Without the flag the response is what it always was. The widget's own
// configuration picker does not want catalogues, and building them walks
// moment_kinds once per connection.
func TestConnectionsOmitMomentsByDefault(t *testing.T) {
	w := newFeedWorld(t)
	w.newRecord(t, "moment_kinds", map[string]any{
		"pair": w.pair.Id, "slug": "dog_walk", "emoji": "🐕", "label": "Dog walk", "created_by": w.alice.Id,
	})

	connections := w.connections(t, "")

	if _, present := connections[0]["moments"]; present {
		t.Fatalf("expected no moments key, got %v", connections[0])
	}
}
