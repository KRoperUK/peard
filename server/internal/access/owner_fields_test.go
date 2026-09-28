package access

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/core"
)

// An update rule is checked against the record before the update, so a rule
// like `user = @request.auth.id` on its own lets the owner write somebody
// else's id into `user`. These are the records where that would matter: a
// device receives the new owner's pushes, a widget token reads and posts as
// them, and a moment kind or live activity lands in a connection its author
// is not in.

func (w *world) patch(t *testing.T, collection, id, token, body string) (int, string) {
	t.Helper()
	return w.doBody(t, http.MethodPatch, "/api/collections/"+collection+"/records/"+id, token,
		"application/json", []byte(body))
}

func (w *world) create(t *testing.T, collection string, fields map[string]any) *core.Record {
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

func (w *world) widgetToken(t *testing.T, token string) (id, secret string) {
	t.Helper()

	status, body := w.doBody(t, http.MethodPost, "/api/peard/widget/token", token, "application/json", []byte(`{}`))
	if status != http.StatusOK {
		t.Fatalf("issue widget token: %d %s", status, body)
	}
	var out struct {
		ID    string `json:"id"`
		Token string `json:"token"`
	}
	if err := json.Unmarshal([]byte(body), &out); err != nil || out.ID == "" || out.Token == "" {
		t.Fatalf("widget token response %q: %v", body, err)
	}
	return out.ID, out.Token
}

func (w *world) field(t *testing.T, collection, id, name string) string {
	t.Helper()

	r, err := w.app.FindRecordById(collection, id)
	if err != nil {
		t.Fatalf("reload %s %s: %v", collection, id, err)
	}
	return r.GetString(name)
}

func TestAnUpdateCannotHandARecordToSomebodyElse(t *testing.T) {
	w := newWorld(t)

	device := w.create(t, "devices", map[string]any{"user": w.mallory.Id, "platform": "ios", "push_token": "mallory-phone"})
	activity := w.create(t, "live_activities", map[string]any{"user": w.bob.Id, "pair": w.flatmates.Id, "push_token": "bob-activity"})
	tokenID, secret := w.widgetToken(t, w.malTok)

	cases := []struct {
		name, collection, id, token, body, field, want string
	}{
		{"device to another user", "devices", device.Id, w.malTok,
			fmt.Sprintf(`{"user":%q}`, w.alice.Id), "user", w.mallory.Id},
		{"widget token to another user", "widget_tokens", tokenID, w.malTok,
			fmt.Sprintf(`{"user":%q}`, w.alice.Id), "user", w.mallory.Id},
		{"widget token secret", "widget_tokens", tokenID, w.malTok,
			`{"token":"chosen-by-mallory"}`, "token", secret},
		{"moment kind into another connection", "moment_kinds", w.aliceKind.Id, w.bobTok,
			fmt.Sprintf(`{"pair":%q}`, w.strangers.Id), "pair", w.flatmates.Id},
		{"moment kind's author", "moment_kinds", w.aliceKind.Id, w.bobTok,
			fmt.Sprintf(`{"created_by":%q}`, w.bob.Id), "created_by", w.alice.Id},
		{"live activity to another user", "live_activities", activity.Id, w.bobTok,
			fmt.Sprintf(`{"user":%q}`, w.alice.Id), "user", w.bob.Id},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			status, body := w.patch(t, c.collection, c.id, c.token, c.body)
			if status < 400 {
				t.Errorf("PATCH answered %d %s, want a refusal", status, body)
			}
			if got := w.field(t, c.collection, c.id, c.field); got != c.want {
				t.Errorf("%s is now %q, want %q", c.field, got, c.want)
			}
		})
	}

	status, body := w.do(t, http.MethodGet, "/api/peard/widget/connections?token="+secret, "")
	if strings.Contains(body, "Flatmates") {
		t.Errorf("mallory's widget token reads alice's connections: %d %s", status, body)
	}
}

// The same rules must still let the app do what it does: re-register a device
// or activity (resending its own `user` and `pair`), rename a moment, and
// revoke a widget token.
func TestOwnersCanStillUpdateTheirOwnRecords(t *testing.T) {
	w := newWorld(t)

	device := w.create(t, "devices", map[string]any{"user": w.alice.Id, "platform": "ios", "push_token": "alice-phone"})
	activity := w.create(t, "live_activities", map[string]any{"user": w.alice.Id, "pair": w.flatmates.Id, "push_token": "alice-activity"})
	tokenID, _ := w.widgetToken(t, w.aliceTok)

	cases := []struct {
		name, collection, id, token, body string
	}{
		{"device upsert", "devices", device.Id, w.aliceTok,
			fmt.Sprintf(`{"user":%q,"platform":"ios","push_token":"alice-phone"}`, w.alice.Id)},
		{"activity token refresh", "live_activities", activity.Id, w.aliceTok,
			fmt.Sprintf(`{"user":%q,"pair":%q,"push_token":"alice-activity-2"}`, w.alice.Id, w.flatmates.Id)},
		{"rename a moment", "moment_kinds", w.aliceKind.Id, w.bobTok,
			`{"emoji":"🍷","label":"Wine"}`},
		{"revoke a widget token", "widget_tokens", tokenID, w.aliceTok,
			`{"revoked":true}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if status, body := w.patch(t, c.collection, c.id, c.token, c.body); status != http.StatusOK {
				t.Errorf("PATCH answered %d %s, want 200", status, body)
			}
		})
	}
}
