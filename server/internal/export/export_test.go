// The account data export.
//
// External to `export` so the real schema can come from blank-importing
// `peard/migrations`, matching the other packages' tests.
//
// These pin what the export returns today: whose data it may contain, and the
// fields it carries. What it ought to contain beyond that is a separate issue.
// The field checks look for what is there rather than insisting nothing else
// is, so the export can grow without these needing to be rewritten.
package export_test

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
	"github.com/pocketbase/pocketbase/tools/filesystem"

	"peard/internal/export"

	_ "peard/migrations"
)

// onePixelPNG is a valid 1×1 PNG. PocketBase sniffs the bytes against the
// field's allowed types, so a placeholder string would be refused.
const onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="

// exportWorld is alice, the caller, in a connection with bob, plus carol, an
// outsider in a connection of her own. Every record of carol's carries a
// distinctive string, so leaking any of it shows up in a plain search of the
// response body.
type exportWorld struct {
	app *tests.TestApp
	mux http.Handler

	alice, bob, carol *core.Record
	aliceTok          string
	flatmates         *core.Record
	elsewhere         *core.Record
	aliceMembership   *core.Record

	alicePost, alicePhoto *core.Record
	bobPost               *core.Record
	carolPost             *core.Record
}

func newExportWorld(t *testing.T) *exportWorld {
	t.Helper()

	dir, err := os.MkdirTemp("", "peard-export-test-*")
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

	export.Register(app)

	w := &exportWorld{app: app}
	w.seed(t)

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

func (w *exportWorld) seed(t *testing.T) {
	t.Helper()

	w.alice = w.newUser(t, "alice@example.com", "Alice Anderson")
	w.bob = w.newUser(t, "bob@example.com", "Bob Brown")
	w.carol = w.newUser(t, "carol-outsider@example.com", "Carol Outsider")

	token, err := w.alice.NewAuthToken()
	if err != nil {
		t.Fatalf("auth token: %v", err)
	}
	w.aliceTok = token

	w.flatmates = w.newRecord(t, "pairs", map[string]any{"name": "Flatmates"})
	w.elsewhere = w.newRecord(t, "pairs", map[string]any{"name": "Carol's secret group"})

	w.aliceMembership = w.newRecord(t, "pair_members", map[string]any{
		"pair": w.flatmates.Id, "user": w.alice.Id, "role": "owner", "muted": true,
	})
	w.newRecord(t, "pair_members", map[string]any{"pair": w.flatmates.Id, "user": w.bob.Id, "role": "member"})
	w.newRecord(t, "pair_members", map[string]any{"pair": w.elsewhere.Id, "user": w.carol.Id, "role": "owner"})

	w.alicePost = w.newRecord(t, "posts", map[string]any{
		"pair": w.flatmates.Id, "author": w.alice.Id,
		"type": "event", "event_kind": "beer", "note": "alice at the pub",
		"happened_at": "2026-09-01 20:00:00.000Z", "rewound": true,
	})

	raw, err := base64.StdEncoding.DecodeString(onePixelPNG)
	if err != nil {
		t.Fatalf("decode png: %v", err)
	}
	file, err := filesystem.NewFileFromBytes(raw, "photo.png")
	if err != nil {
		t.Fatalf("build file: %v", err)
	}
	w.alicePhoto = w.newRecord(t, "posts", map[string]any{
		"pair": w.flatmates.Id, "author": w.alice.Id,
		"type": "photo", "media": []*filesystem.File{file},
	})

	// bob's moment is in alice's connection, but the export is of what alice
	// authored, so it stays out.
	w.bobPost = w.newRecord(t, "posts", map[string]any{
		"pair": w.flatmates.Id, "author": w.bob.Id,
		"type": "event", "event_kind": "coffee", "note": "bob-only note",
	})
	w.carolPost = w.newRecord(t, "posts", map[string]any{
		"pair": w.elsewhere.Id, "author": w.carol.Id,
		"type": "event", "event_kind": "coffee", "note": "carol-outsider note",
	})
}

func (w *exportWorld) newUser(t *testing.T, email, name string) *core.Record {
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

func (w *exportWorld) newRecord(t *testing.T, collection string, fields map[string]any) *core.Record {
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

func (w *exportWorld) get(t *testing.T, path, token string) (int, string) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if token != "" {
		req.Header.Set("Authorization", token)
	}
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	return rec.Code, rec.Body.String()
}

type exportPayload struct {
	ExportedAt  string           `json:"exported_at"`
	MediaNote   string           `json:"media_note"`
	Profile     map[string]any   `json:"profile"`
	Connections []map[string]any `json:"connections"`
	Moments     []map[string]any `json:"moments"`
}

// export fetches alice's export, failing on anything but a clean 200 so a broken
// route can never pass as "nothing leaked".
func (w *exportWorld) export(t *testing.T) (exportPayload, string) {
	t.Helper()
	status, body := w.get(t, "/api/peard/export", w.aliceTok)
	if status != http.StatusOK {
		t.Fatalf("export: status %d, body %s", status, body)
	}
	var p exportPayload
	if err := json.Unmarshal([]byte(body), &p); err != nil {
		t.Fatalf("decode export: %v; body %s", err, body)
	}
	return p, body
}

func TestExportRequiresAuth(t *testing.T) {
	w := newExportWorld(t)

	status, body := w.get(t, "/api/peard/export", "")
	if status != http.StatusUnauthorized {
		t.Errorf("anonymous export: status %d, want 401; body %s", status, body)
	}
}

func TestExportNeverContainsAnOutsidersData(t *testing.T) {
	w := newExportWorld(t)
	_, body := w.export(t)

	for what, needle := range map[string]string{
		"carol's id":                          w.carol.Id,
		"carol's email":                       w.carol.Email(),
		"carol's name":                        "Carol Outsider",
		"carol's connection id":               w.elsewhere.Id,
		"carol's connection name":             "Carol's secret group",
		"carol's moment id":                   w.carolPost.Id,
		"carol's note":                        "carol-outsider note",
		"bob's moment in a shared connection": w.bobPost.Id,
		"bob's note":                          "bob-only note",
		"bob's email":                         w.bob.Email(),
	} {
		if strings.Contains(body, needle) {
			t.Errorf("export contains %s (%q)", what, needle)
		}
	}
}

func TestExportContainsCallersProfile(t *testing.T) {
	w := newExportWorld(t)
	p, _ := w.export(t)

	want := map[string]string{
		"id":           w.alice.Id,
		"email":        "alice@example.com",
		"display_name": "Alice Anderson",
	}
	for k, v := range want {
		if got, _ := p.Profile[k].(string); got != v {
			t.Errorf("profile.%s = %q, want %q", k, got, v)
		}
	}
	if p.ExportedAt == "" {
		t.Error("exported_at is empty")
	}
	if p.MediaNote == "" {
		t.Error("media_note is empty: the photo links expire, and the export must say so")
	}
}

func TestExportContainsCallersConnections(t *testing.T) {
	w := newExportWorld(t)
	p, _ := w.export(t)

	if len(p.Connections) != 1 {
		t.Fatalf("connections = %d, want 1: %v", len(p.Connections), p.Connections)
	}
	c := p.Connections[0]
	for k, v := range map[string]any{
		"id":     w.flatmates.Id,
		"name":   "Flatmates",
		"role":   "owner",
		"joined": w.aliceMembership.GetString("created"),
		"muted":  true,
	} {
		if c[k] != v {
			t.Errorf("connection.%s = %v, want %v", k, c[k], v)
		}
	}
}

func TestExportContainsCallersMoments(t *testing.T) {
	w := newExportWorld(t)
	p, _ := w.export(t)

	byID := map[string]map[string]any{}
	for _, m := range p.Moments {
		id, _ := m["id"].(string)
		byID[id] = m
	}
	if len(byID) != 2 {
		t.Fatalf("moments = %d, want alice's 2: %v", len(p.Moments), p.Moments)
	}

	event, ok := byID[w.alicePost.Id]
	if !ok {
		t.Fatalf("alice's event moment %s missing", w.alicePost.Id)
	}
	for k, v := range map[string]any{
		"pair":        w.flatmates.Id,
		"type":        "event",
		"event_kind":  "beer",
		"note":        "alice at the pub",
		"created":     w.alicePost.GetString("created"),
		"happened_at": w.alicePost.GetString("happened_at"),
		"rewound":     true,
	} {
		if event[k] != v {
			t.Errorf("moment.%s = %v, want %v", k, event[k], v)
		}
	}
	if _, has := event["media_url"]; has {
		t.Errorf("a moment with no photo has media_url %v", event["media_url"])
	}

	photo, ok := byID[w.alicePhoto.Id]
	if !ok {
		t.Fatalf("alice's photo moment %s missing", w.alicePhoto.Id)
	}
	if photo["type"] != "photo" {
		t.Errorf("photo moment type = %v, want photo", photo["type"])
	}
	raw, _ := photo["media_url"].(string)
	link, err := url.Parse(raw)
	if err != nil || raw == "" {
		t.Fatalf("photo moment media_url = %q, want a URL (%v)", raw, err)
	}
	wantPath := "/api/files/" + w.alicePhoto.Collection().Id + "/" + w.alicePhoto.Id + "/" + w.alicePhoto.GetString("media")
	if link.Path != wantPath {
		t.Errorf("media_url path = %q, want %q", link.Path, wantPath)
	}
	if link.Query().Get("token") == "" {
		t.Fatalf("media_url %q carries no file token, so the protected photo cannot be opened", raw)
	}

	// The link is only worth exporting if it opens: media is a protected field,
	// so without the token this would be a 404.
	if status, body := w.get(t, link.RequestURI(), ""); status != http.StatusOK {
		t.Errorf("fetching the exported photo link: status %d, body %s", status, body)
	}
}
