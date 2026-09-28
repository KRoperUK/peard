// The account data export.
//
// External to `export` so the real schema can come from blank-importing
// `peard/migrations`, matching the other packages' tests.
//
// These pin whose data the export may contain, that it carries everything held
// about the caller, that it never carries a usable secret, and that it pages
// through a long history instead of stopping short. The field checks look for
// what is there rather than insisting nothing else is, so the export can grow
// without these needing to be rewritten.
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

	aliceReaction, bobReaction *core.Record
	aliceKind, carolKind       *core.Record
	aliceDevice, carolDevice   *core.Record
	aliceWidget, carolWidget   *core.Record
	aliceActivity              *core.Record
	aliceInvite                *core.Record
}

// Secrets seeded for alice. None of them may appear whole in her export.
const (
	alicePushToken     = "alice-apns-device-token-0123456789abcdef"
	aliceStartToken    = "alice-activity-start-token-fedcba987654"
	aliceWidgetSecret  = "alice-widget-secret-never-exported"
	aliceActivityToken = "alice-live-activity-token-never-exported"
	aliceInviteCode    = "ALIC3X"
)

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

	avatar, err := filesystem.NewFileFromBytes(raw, "me.png")
	if err != nil {
		t.Fatalf("build avatar: %v", err)
	}
	w.alice.Set("phone", "+44 7700 900123")
	w.alice.Set("contact_email", "alice.contact@example.com")
	w.alice.Set("discoverable", true)
	w.alice.Set("avatar", []*filesystem.File{avatar})
	if err := w.app.Save(w.alice); err != nil {
		t.Fatalf("save alice's profile: %v", err)
	}

	// alice's reaction is on her own photo: one on bob's moment would carry its
	// id, which the outsider test rightly counts as bob's.
	w.aliceReaction = w.newRecord(t, "reactions", map[string]any{"post": w.alicePhoto.Id, "user": w.alice.Id, "kind": "cheers"})
	w.bobReaction = w.newRecord(t, "reactions", map[string]any{"post": w.alicePost.Id, "user": w.bob.Id, "kind": "heart"})

	w.aliceKind = w.newRecord(t, "moment_kinds", map[string]any{
		"pair": w.flatmates.Id, "slug": "karaoke", "emoji": "🎤", "label": "Karaoke", "created_by": w.alice.Id,
	})
	w.carolKind = w.newRecord(t, "moment_kinds", map[string]any{
		"pair": w.elsewhere.Id, "slug": "carol-kind", "emoji": "🫖", "label": "Carol's tea", "created_by": w.carol.Id,
	})

	w.aliceDevice = w.newRecord(t, "devices", map[string]any{
		"user": w.alice.Id, "platform": "ios", "push_token": alicePushToken, "activity_start_token": aliceStartToken,
	})
	w.carolDevice = w.newRecord(t, "devices", map[string]any{"user": w.carol.Id, "platform": "ios", "push_token": "carol-push-token-xyz"})

	w.aliceWidget = w.newRecord(t, "widget_tokens", map[string]any{
		"user": w.alice.Id, "token": aliceWidgetSecret, "label": "Home screen",
		"expires": "2027-01-01 00:00:00.000Z", "revoked": true,
	})
	w.carolWidget = w.newRecord(t, "widget_tokens", map[string]any{"user": w.carol.Id, "token": "carol-widget-secret", "label": "carol-widget"})

	w.aliceActivity = w.newRecord(t, "live_activities", map[string]any{
		"user": w.alice.Id, "pair": w.flatmates.Id, "push_token": aliceActivityToken,
		"expires": "2026-09-01 20:30:00.000Z",
	})
	w.newRecord(t, "live_activities", map[string]any{"user": w.carol.Id, "pair": w.elsewhere.Id, "push_token": "carol-activity-token"})

	w.aliceInvite = w.newRecord(t, "pair_invites", map[string]any{
		"code": aliceInviteCode, "inviter": w.alice.Id, "pair": w.flatmates.Id,
		"status": "pending", "expires": "2026-09-02 20:00:00.000Z",
	})
	w.newRecord(t, "pair_invites", map[string]any{"code": "CAROL1", "inviter": w.carol.Id, "status": "pending"})
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
	ExportedAt     string           `json:"exported_at"`
	MediaNote      string           `json:"media_note"`
	TokenNote      string           `json:"token_note"`
	Profile        map[string]any   `json:"profile"`
	Connections    []map[string]any `json:"connections"`
	Invites        []map[string]any `json:"invites"`
	Moments        []map[string]any `json:"moments"`
	Reactions      []map[string]any `json:"reactions"`
	MomentKinds    []map[string]any `json:"moment_kinds"`
	Devices        []map[string]any `json:"devices"`
	WidgetTokens   []map[string]any `json:"widget_tokens"`
	LiveActivities []map[string]any `json:"live_activities"`
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
		"bob's reaction":                      w.bobReaction.Id,
		"carol's moment kind":                 w.carolKind.Id,
		"carol's moment kind label":           "Carol's tea",
		"carol's device":                      w.carolDevice.Id,
		"carol's widget token":                w.carolWidget.Id,
		"carol's widget label":                "carol-widget",
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

// byID indexes a list of exported rows by their id field.
func byID(rows []map[string]any) map[string]map[string]any {
	out := map[string]map[string]any{}
	for _, r := range rows {
		id, _ := r["id"].(string)
		out[id] = r
	}
	return out
}

// only fails unless rows holds exactly the one record wanted, and returns it.
func only(t *testing.T, what string, rows []map[string]any, want *core.Record) map[string]any {
	t.Helper()
	if len(rows) != 1 {
		t.Fatalf("%s = %d rows, want 1: %v", what, len(rows), rows)
	}
	row, ok := byID(rows)[want.Id]
	if !ok {
		t.Fatalf("%s: %s missing from %v", what, want.Id, rows)
	}
	return row
}

func checkFields(t *testing.T, what string, row map[string]any, want map[string]any) {
	t.Helper()
	for k, v := range want {
		if row[k] != v {
			t.Errorf("%s.%s = %v, want %v", what, k, row[k], v)
		}
	}
}

func TestExportContainsCallersFullProfile(t *testing.T) {
	w := newExportWorld(t)
	p, _ := w.export(t)

	checkFields(t, "profile", p.Profile, map[string]any{
		"phone":         "+44 7700 900123",
		"contact_email": "alice.contact@example.com",
		"discoverable":  true,
		"avatar":        w.alice.GetString("avatar"),
		"created":       w.alice.GetString("created"),
	})

	raw, _ := p.Profile["avatar_url"].(string)
	link, err := url.Parse(raw)
	if err != nil || raw == "" {
		t.Fatalf("profile.avatar_url = %q, want a URL (%v)", raw, err)
	}
	// users.avatar is protected too, so the link needs the file token to open.
	if status, body := w.get(t, link.RequestURI(), ""); status != http.StatusOK {
		t.Errorf("fetching the exported avatar link: status %d, body %s", status, body)
	}
}

func TestExportContainsCallersReactionsAndKinds(t *testing.T) {
	w := newExportWorld(t)
	p, _ := w.export(t)

	checkFields(t, "reaction", only(t, "reactions", p.Reactions, w.aliceReaction), map[string]any{
		"moment":  w.alicePhoto.Id,
		"kind":    "cheers",
		"created": w.aliceReaction.GetString("created"),
	})
	checkFields(t, "moment_kind", only(t, "moment_kinds", p.MomentKinds, w.aliceKind), map[string]any{
		"pair":    w.flatmates.Id,
		"slug":    "karaoke",
		"emoji":   "🎤",
		"label":   "Karaoke",
		"created": w.aliceKind.GetString("created"),
	})
}

func TestExportContainsCallersDevicesAndTokens(t *testing.T) {
	w := newExportWorld(t)
	p, _ := w.export(t)

	checkFields(t, "device", only(t, "devices", p.Devices, w.aliceDevice), map[string]any{
		"platform":             "ios",
		"created":              w.aliceDevice.GetString("created"),
		"push_token":           "…abcdef",
		"activity_start_token": "…987654",
	})
	checkFields(t, "widget_token", only(t, "widget_tokens", p.WidgetTokens, w.aliceWidget), map[string]any{
		"label":   "Home screen",
		"created": w.aliceWidget.GetString("created"),
		"expires": w.aliceWidget.GetString("expires"),
		"revoked": true,
	})
	checkFields(t, "live_activity", only(t, "live_activities", p.LiveActivities, w.aliceActivity), map[string]any{
		"pair":    w.flatmates.Id,
		"created": w.aliceActivity.GetString("created"),
		"expires": w.aliceActivity.GetString("expires"),
	})
	checkFields(t, "invite", only(t, "invites", p.Invites, w.aliceInvite), map[string]any{
		"direction": "sent",
		"pair":      w.flatmates.Id,
		"status":    "pending",
		"expires":   w.aliceInvite.GetString("expires"),
	})
	if p.TokenNote == "" {
		t.Error("token_note is empty: the export masks tokens, and must say why")
	}
}

// A push token, widget secret or invite code in a file the user may mail to
// themselves or leave in a cloud drive is a credential out in the open; the
// export says they exist without handing them over.
func TestExportNeverContainsASecret(t *testing.T) {
	w := newExportWorld(t)
	_, body := w.export(t)

	for what, needle := range map[string]string{
		"push token":           alicePushToken,
		"activity start token": aliceStartToken,
		"widget secret":        aliceWidgetSecret,
		"live activity token":  aliceActivityToken,
		"invite code":          aliceInviteCode,
		"carol's push token":   "carol-push-token-xyz",
	} {
		if strings.Contains(body, needle) {
			t.Errorf("export contains %s (%q)", what, needle)
		}
	}
}

// The export used to stop at a fixed number of moments without saying so. With
// the page shrunk to two rows, a list that needs several pages must still come
// back whole.
func TestExportPagesThroughEverything(t *testing.T) {
	w := newExportWorld(t)
	defer export.SetPageSize(2)()

	want := map[string]bool{w.alicePost.Id: true, w.alicePhoto.Id: true}
	for i := 0; i < 5; i++ {
		post := w.newRecord(t, "posts", map[string]any{
			"pair": w.flatmates.Id, "author": w.alice.Id, "type": "event", "event_kind": "beer",
		})
		want[post.Id] = true
	}

	p, _ := w.export(t)
	got := byID(p.Moments)
	if len(p.Moments) != len(want) {
		t.Errorf("moments = %d, want all %d", len(p.Moments), len(want))
	}
	for id := range want {
		if _, ok := got[id]; !ok {
			t.Errorf("moment %s missing from a paged export", id)
		}
	}
}
