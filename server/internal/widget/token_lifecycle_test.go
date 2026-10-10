package widget_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/tools/types"
)

// A widget token lives in the App Group container, not behind the Keychain, so
// it is meant to expire, stay bounded in number, and be revocable. These cover
// the mint path setting an expiry, the per-user cap and prune, and the revoke
// route (#340).

// authToken is a PocketBase session token for a seeded user, for the routes that
// require one (mint and revoke) rather than the widget token.
func (w *feedWorld) authToken(t *testing.T, userID string) string {
	t.Helper()
	u, err := w.app.FindRecordById("users", userID)
	if err != nil {
		t.Fatalf("reload user %s: %v", userID, err)
	}
	tok, err := u.NewAuthToken()
	if err != nil {
		t.Fatalf("auth token: %v", err)
	}
	return tok
}

func (w *feedWorld) do(t *testing.T, method, path, auth, body string) (int, string) {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	return rec.Code, rec.Body.String()
}

func (w *feedWorld) countTokens(t *testing.T, userID string) int {
	t.Helper()
	n, err := w.app.CountRecords("widget_tokens", dbx.HashExp{"user": userID})
	if err != nil {
		t.Fatalf("count tokens: %v", err)
	}
	return int(n)
}

func (w *feedWorld) mint(t *testing.T, userID string) string {
	t.Helper()
	status, body := w.do(t, http.MethodPost, "/api/peard/widget/token", w.authToken(t, userID), "{}")
	if status != http.StatusOK {
		t.Fatalf("mint: %d %s", status, body)
	}
	var res struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal([]byte(body), &res); err != nil {
		t.Fatalf("decode mint: %v (%s)", err, body)
	}
	return res.Token
}

// A freshly minted token carries an expiry, so an immortal credential cannot be
// issued (the whole point of #340).
func TestMintedTokenHasAnExpiry(t *testing.T) {
	w := newFeedWorld(t)
	token := w.mint(t, w.alice.Id)

	rec, err := w.app.FindFirstRecordByFilter("widget_tokens", "token = {:t}", dbx.Params{"t": token})
	if err != nil {
		t.Fatalf("find minted token: %v", err)
	}
	exp := rec.GetDateTime("expires")
	if exp.IsZero() {
		t.Fatal("minted token has no expiry")
	}
	life := time.Until(exp.Time())
	if life <= 0 || life > 31*24*time.Hour {
		t.Errorf("token lives %v, want a bounded future window", life)
	}
}

// labelOf returns the stored label for a minted token secret.
func (w *feedWorld) labelOf(t *testing.T, token string) string {
	t.Helper()
	rec, err := w.app.FindFirstRecordByFilter("widget_tokens", "token = {:t}", dbx.Params{"t": token})
	if err != nil {
		t.Fatalf("find token: %v", err)
	}
	return rec.GetString("label")
}

// mintWithBody mints with a raw JSON body, so a label (or its absence) can be
// exercised.
func (w *feedWorld) mintWithBody(t *testing.T, userID, body string) string {
	t.Helper()
	status, resp := w.do(t, http.MethodPost, "/api/peard/widget/token", w.authToken(t, userID), body)
	if status != http.StatusOK {
		t.Fatalf("mint: %d %s", status, resp)
	}
	var res struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal([]byte(resp), &res); err != nil {
		t.Fatalf("decode mint: %v (%s)", err, resp)
	}
	return res.Token
}

// A client-sent device label names the row in the devices list (#379).
func TestMintStoresTheDeviceLabel(t *testing.T) {
	w := newFeedWorld(t)
	token := w.mintWithBody(t, w.alice.Id, `{"label":"iPad"}`)
	if got := w.labelOf(t, token); got != "iPad" {
		t.Errorf("label = %q, want %q", got, "iPad")
	}
}

// An older client sends no label; the server falls back to its generic one so
// the row is never blank.
func TestMintFallsBackToAGenericLabel(t *testing.T) {
	w := newFeedWorld(t)
	token := w.mintWithBody(t, w.alice.Id, "{}")
	if got := w.labelOf(t, token); got != "ios-widget" {
		t.Errorf("label = %q, want the fallback %q", got, "ios-widget")
	}
	// Whitespace is the same as nothing.
	token2 := w.mintWithBody(t, w.alice.Id, `{"label":"   "}`)
	if got := w.labelOf(t, token2); got != "ios-widget" {
		t.Errorf("whitespace label = %q, want the fallback", got)
	}
}

// A label is a display hint, never trusted: an overlong one is capped so it
// cannot bloat the row.
func TestMintCapsAnOverlongLabel(t *testing.T) {
	w := newFeedWorld(t)
	long := strings.Repeat("x", 200)
	token := w.mintWithBody(t, w.alice.Id, `{"label":"`+long+`"}`)
	if got := len(w.labelOf(t, token)); got != 60 {
		t.Errorf("label length = %d, want it capped at 60", got)
	}
}

// Minting prunes the user's already-expired rows, so dead tokens do not pile up.
func TestMintPrunesExpiredTokens(t *testing.T) {
	w := newFeedWorld(t)
	// A stale row for alice, expired an hour ago.
	w.newRecord(t, "widget_tokens", map[string]any{
		"user":    w.alice.Id,
		"token":   "stale-token",
		"expires": time.Now().Add(-time.Hour).UTC().Format(types.DefaultDateLayout),
	})
	// The seed also made one unexpired token ("widget-token-for-alice") with no
	// expiry; it is live, so it survives. Minting should drop the stale one.
	before := w.countTokens(t, w.alice.Id)
	w.mint(t, w.alice.Id)

	if w.exists(t, "stale-token") {
		t.Error("an expired token survived a mint")
	}
	// before (2: seed + stale) - 1 pruned + 1 minted = 2.
	if got := w.countTokens(t, w.alice.Id); got != before {
		t.Errorf("tokens after mint = %d, want %d", got, before)
	}
}

// A user cannot accumulate tokens without bound: once at the cap, minting
// retires the oldest.
func TestMintCapsTokensPerUser(t *testing.T) {
	w := newFeedWorld(t)
	// Fill well past the cap with live (future-dated) tokens.
	for i := 0; i < 15; i++ {
		w.newRecord(t, "widget_tokens", map[string]any{
			"user":    w.alice.Id,
			"token":   "live-" + string(rune('a'+i)),
			"expires": time.Now().Add(24 * time.Hour).UTC().Format(types.DefaultDateLayout),
		})
		time.Sleep(2 * time.Millisecond) // distinct `created` ordering
	}
	w.mint(t, w.alice.Id)

	if got := w.countTokens(t, w.alice.Id); got > 10 {
		t.Errorf("tokens after mint at cap = %d, want <= 10", got)
	}
	// The very first token ("live-a") is the oldest and should be gone.
	if w.exists(t, "live-a") {
		t.Error("the oldest token was not retired past the cap")
	}
}

// Revoke drops the caller's own token server-side, so sign-out invalidates it.
func TestRevokeDropsOwnToken(t *testing.T) {
	w := newFeedWorld(t)
	token := w.mint(t, w.alice.Id)

	status, body := w.do(t, http.MethodPost, "/api/peard/widget/revoke",
		w.authToken(t, w.alice.Id), `{"token":"`+token+`"}`)
	if status != http.StatusOK {
		t.Fatalf("revoke: %d %s", status, body)
	}
	if w.exists(t, token) {
		t.Error("the token survived being revoked")
	}
}

// Revoke never touches another user's token: bob cannot drop alice's.
func TestRevokeRefusesAnotherUsersToken(t *testing.T) {
	w := newFeedWorld(t)
	aliceToken := w.mint(t, w.alice.Id)

	status, body := w.do(t, http.MethodPost, "/api/peard/widget/revoke",
		w.authToken(t, w.bob.Id), `{"token":"`+aliceToken+`"}`)
	if status != http.StatusOK {
		t.Fatalf("revoke by other user: %d %s", status, body)
	}
	if !w.exists(t, aliceToken) {
		t.Error("bob revoked alice's token")
	}
}

func (w *feedWorld) exists(t *testing.T, token string) bool {
	t.Helper()
	n, err := w.app.CountRecords("widget_tokens", dbx.HashExp{"token": token})
	if err != nil {
		t.Fatalf("count token: %v", err)
	}
	return n > 0
}
