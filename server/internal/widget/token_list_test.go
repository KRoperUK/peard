package widget_test

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

// The "Signed-in devices & widgets" screen lists a user's live widget tokens and
// revokes them by id (#367). The list must never carry the secret, and revoke by
// id must be as owner-only and idempotent as revoke by token.

type listedToken struct {
	ID      string `json:"id"`
	Label   string `json:"label"`
	Created string `json:"created"`
	Expires string `json:"expires"`
}

func (w *feedWorld) listTokens(t *testing.T, userID string) ([]listedToken, string) {
	t.Helper()
	status, body := w.do(t, http.MethodGet, "/api/peard/widget/tokens", w.authToken(t, userID), "")
	if status != http.StatusOK {
		t.Fatalf("list tokens: %d %s", status, body)
	}
	var res struct {
		Tokens []listedToken `json:"tokens"`
	}
	if err := json.Unmarshal([]byte(body), &res); err != nil {
		t.Fatalf("decode list: %v (%s)", err, body)
	}
	return res.Tokens, body
}

func (w *feedWorld) tokenRecord(t *testing.T, userID, token, label string, expires time.Time, revoked bool) *core.Record {
	t.Helper()
	return w.newRecord(t, "widget_tokens", map[string]any{
		"user":    userID,
		"token":   token,
		"label":   label,
		"expires": expires.UTC().Format(types.DefaultDateLayout),
		"revoked": revoked,
	})
}

func (w *feedWorld) existsID(t *testing.T, id string) bool {
	t.Helper()
	_, err := w.app.FindRecordById("widget_tokens", id)
	return err == nil
}

func TestListTokensReturnsCallersLiveTokens(t *testing.T) {
	w := newFeedWorld(t)
	future := time.Now().Add(24 * time.Hour)
	mine := w.tokenRecord(t, w.alice.Id, "alice-phone-secret", "ios-widget", future, false)
	w.tokenRecord(t, w.bob.Id, "bob-phone-secret", "ios-widget", future, false)

	got, _ := w.listTokens(t, w.alice.Id)

	var found bool
	for _, tok := range got {
		if tok.ID == mine.Id {
			found = true
			if tok.Label != "ios-widget" || tok.Created == "" || tok.Expires == "" {
				t.Errorf("listed token is missing fields: %+v", tok)
			}
		}
	}
	if !found {
		t.Errorf("alice's token %s missing from %+v", mine.Id, got)
	}
}

func TestListTokensExcludesRevokedExpiredAndOtherUsers(t *testing.T) {
	w := newFeedWorld(t)
	future := time.Now().Add(24 * time.Hour)
	revoked := w.tokenRecord(t, w.alice.Id, "alice-revoked-secret", "revoked", future, true)
	expired := w.tokenRecord(t, w.alice.Id, "alice-expired-secret", "expired", time.Now().Add(-time.Hour), false)
	theirs := w.tokenRecord(t, w.bob.Id, "bob-secret", "bobs", future, false)

	got, _ := w.listTokens(t, w.alice.Id)

	for _, tok := range got {
		switch tok.ID {
		case revoked.Id:
			t.Error("a revoked token was listed")
		case expired.Id:
			t.Error("an expired token was listed")
		case theirs.Id:
			t.Error("another user's token was listed")
		}
	}
}

// The secret is a bearer credential; the list is the one place it would be easy
// to leak, so check the raw body rather than only the decoded fields.
func TestListTokensNeverIncludesTheSecret(t *testing.T) {
	w := newFeedWorld(t)
	w.tokenRecord(t, w.alice.Id, "alice-very-secret-value", "ios-widget", time.Now().Add(time.Hour), false)

	_, body := w.listTokens(t, w.alice.Id)

	for _, secret := range []string{"alice-very-secret-value", w.token} {
		if strings.Contains(body, secret) {
			t.Errorf("list body leaked a token secret: %s", body)
		}
	}
	if strings.Contains(body, `"token"`) {
		t.Errorf("list body carries a token field: %s", body)
	}
}

// The seeded token has no expiry (a row from before #340). It must list with a
// null `expires`, not an empty string, which the app's date decoder rejects.
func TestListTokensNullExpiryForLegacyRows(t *testing.T) {
	w := newFeedWorld(t)

	_, body := w.listTokens(t, w.alice.Id)

	if !strings.Contains(body, `"expires":null`) {
		t.Errorf("a token with no expiry should list expires:null, got %s", body)
	}
}

func TestListTokensRequiresAuth(t *testing.T) {
	w := newFeedWorld(t)
	status, _ := w.do(t, http.MethodGet, "/api/peard/widget/tokens", "", "")
	if status != http.StatusUnauthorized && status != http.StatusForbidden {
		t.Errorf("unauthenticated list = %d, want 401/403", status)
	}
}

func TestRevokeByIDDropsOwnToken(t *testing.T) {
	w := newFeedWorld(t)
	rec := w.tokenRecord(t, w.alice.Id, "alice-by-id", "ios-widget", time.Now().Add(time.Hour), false)

	status, body := w.do(t, http.MethodPost, "/api/peard/widget/revoke",
		w.authToken(t, w.alice.Id), `{"id":"`+rec.Id+`"}`)
	if status != http.StatusOK {
		t.Fatalf("revoke by id: %d %s", status, body)
	}
	if !strings.Contains(body, `"revoked":true`) {
		t.Errorf("body = %s, want revoked:true", body)
	}
	if w.existsID(t, rec.Id) {
		t.Error("the token survived being revoked by id")
	}
	got, _ := w.listTokens(t, w.alice.Id)
	for _, tok := range got {
		if tok.ID == rec.Id {
			t.Error("a revoked token is still listed")
		}
	}
}

func TestRevokeByIDRefusesAnotherUsersToken(t *testing.T) {
	w := newFeedWorld(t)
	rec := w.tokenRecord(t, w.alice.Id, "alice-guarded", "ios-widget", time.Now().Add(time.Hour), false)

	status, body := w.do(t, http.MethodPost, "/api/peard/widget/revoke",
		w.authToken(t, w.bob.Id), `{"id":"`+rec.Id+`"}`)
	if status != http.StatusOK {
		t.Fatalf("revoke by other user: %d %s", status, body)
	}
	if !strings.Contains(body, `"revoked":false`) {
		t.Errorf("body = %s, want revoked:false", body)
	}
	if !w.existsID(t, rec.Id) {
		t.Error("bob revoked alice's token by id")
	}
}

func TestRevokeByIDIsIdempotent(t *testing.T) {
	w := newFeedWorld(t)
	rec := w.tokenRecord(t, w.alice.Id, "alice-twice", "ios-widget", time.Now().Add(time.Hour), false)
	auth := w.authToken(t, w.alice.Id)
	payload := `{"id":"` + rec.Id + `"}`

	for i := 0; i < 2; i++ {
		status, body := w.do(t, http.MethodPost, "/api/peard/widget/revoke", auth, payload)
		if status != http.StatusOK {
			t.Fatalf("revoke #%d: %d %s", i+1, status, body)
		}
	}
	status, body := w.do(t, http.MethodPost, "/api/peard/widget/revoke", auth, `{"id":"doesnotexist00"}`)
	if status != http.StatusOK {
		t.Errorf("revoke of an unknown id: %d %s", status, body)
	}
}

func TestRevokeNeedsTokenOrID(t *testing.T) {
	w := newFeedWorld(t)
	status, _ := w.do(t, http.MethodPost, "/api/peard/widget/revoke", w.authToken(t, w.alice.Id), `{}`)
	if status != http.StatusBadRequest {
		t.Errorf("empty revoke = %d, want 400", status)
	}
}
