// Package contacts_test is external to `contacts` on purpose: these tests
// need the real Pear'd schema, which comes from blank-importing
// `peard/migrations`, and that package imports `peard/internal/contacts` (to
// share the hash implementation with the backfill migration). An in-package
// test file would make that an import cycle.
package contacts_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"peard/internal/contacts"

	_ "peard/migrations"
)

type harness struct {
	app *tests.TestApp
	mux http.Handler
}

func newHarness(t *testing.T) *harness {
	t.Helper()

	dir, err := os.MkdirTemp("", "peard-contacts-test-*")
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

	contacts.Register(app)

	h := &harness{app: app}
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
		h.mux = mux
		return nil
	}); err != nil {
		t.Fatalf("build mux: %v", err)
	}
	return h
}

func (h *harness) newUser(t *testing.T, email string) (*core.Record, string) {
	t.Helper()
	col, err := h.app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("users collection: %v", err)
	}
	r := core.NewRecord(col)
	r.SetEmail(email)
	r.SetVerified(true)
	r.SetPassword("Password123!")
	if err := h.app.Save(r); err != nil {
		t.Fatalf("save user %s: %v", email, err)
	}
	token, err := r.NewAuthToken()
	if err != nil {
		t.Fatalf("auth token for %s: %v", email, err)
	}
	return r, token
}

func (h *harness) do(t *testing.T, method, url, token string, body any) (int, map[string]any) {
	t.Helper()
	var reader *bytes.Reader
	if body == nil {
		reader = bytes.NewReader(nil)
	} else {
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal body: %v", err)
		}
		reader = bytes.NewReader(encoded)
	}
	req := httptest.NewRequest(method, url, reader)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", token)
	}
	recorder := httptest.NewRecorder()
	h.mux.ServeHTTP(recorder, req)

	var decoded map[string]any
	_ = json.Unmarshal(recorder.Body.Bytes(), &decoded)
	return recorder.Code, decoded
}

func TestHashingIsCaseAndWhitespaceInsensitiveForEmail(t *testing.T) {
	if contacts.HashEmail(" Alex@Example.com ") != contacts.HashEmail("alex@example.com") {
		t.Fatal("expected the same hash regardless of case or surrounding whitespace")
	}
}

func TestHashingIgnoresPhoneFormatting(t *testing.T) {
	if contacts.HashPhone("+44 7888 291038") != contacts.HashPhone("(44) 7888-291038") {
		t.Fatal("expected the same hash once punctuation and spacing are stripped")
	}
}

func TestHashingReturnsEmptyForEmptyInput(t *testing.T) {
	if contacts.HashEmail("") != "" || contacts.HashPhone("") != "" || contacts.HashPhone("   ") != "" {
		t.Fatal("expected empty hashes for empty input, so an unset field never collides with another unset field")
	}
}

func TestRecordHooksKeepHashesInStep(t *testing.T) {
	h := newHarness(t)
	user, _ := h.newUser(t, "alex@example.com")

	if got := user.GetString("email_hash"); got != contacts.HashEmail("alex@example.com") {
		t.Fatalf("email_hash after create = %q, want the hash of the signup email", got)
	}
	if got := user.GetString("phone_hash"); got != "" {
		t.Fatalf("phone_hash after create = %q, want empty (no phone yet)", got)
	}

	user.Set("phone", "+1 555 010 2000")
	if err := h.app.Save(user); err != nil {
		t.Fatalf("save with phone: %v", err)
	}
	if got := user.GetString("phone_hash"); got != contacts.HashPhone("+1 555 010 2000") {
		t.Fatalf("phone_hash after adding a phone = %q, want the hash of that phone", got)
	}
}

func TestMatchFindsOnlyDiscoverableAccounts(t *testing.T) {
	h := newHarness(t)
	alex, alexToken := h.newUser(t, "alex@example.com")
	_, searcherToken := h.newUser(t, "searcher@example.com")

	// Not discoverable yet: a search naming alex's email should find nobody.
	code, resp := h.do(t, "POST", "/api/peard/contacts/match", searcherToken, map[string]any{
		"hashes": []string{contacts.HashEmail("alex@example.com")},
	})
	if code != 200 {
		t.Fatalf("match status = %d, body = %v", code, resp)
	}
	if matches, _ := resp["matches"].([]any); len(matches) != 0 {
		t.Fatalf("expected no matches before opting in, got %v", matches)
	}

	// Opts in via the settings route, the same one the app's toggle calls.
	code, _ = h.do(t, "POST", "/api/peard/contacts/settings", alexToken, map[string]any{
		"discoverable": true,
	})
	if code != 200 {
		t.Fatalf("settings status = %d", code)
	}

	code, resp = h.do(t, "POST", "/api/peard/contacts/match", searcherToken, map[string]any{
		"hashes": []string{contacts.HashEmail("someone-else@example.com"), contacts.HashEmail("alex@example.com")},
	})
	if code != 200 {
		t.Fatalf("match status = %d, body = %v", code, resp)
	}
	matches, _ := resp["matches"].([]any)
	if len(matches) != 1 {
		t.Fatalf("expected exactly one match once alex opted in, got %v", matches)
	}
	match, _ := matches[0].(map[string]any)
	if match["id"] != alex.Id {
		t.Fatalf("matched id = %v, want %v", match["id"], alex.Id)
	}
	if match["hash"] != contacts.HashEmail("alex@example.com") {
		t.Fatalf("matched hash = %v, want the searcher's own submitted hash for alex's email", match["hash"])
	}
}

func TestMatchNeverReturnsTheCallerThemselves(t *testing.T) {
	h := newHarness(t)
	_, token := h.newUser(t, "self@example.com")
	h.do(t, "POST", "/api/peard/contacts/settings", token, map[string]any{"discoverable": true})

	code, resp := h.do(t, "POST", "/api/peard/contacts/match", token, map[string]any{
		"hashes": []string{contacts.HashEmail("self@example.com")},
	})
	if code != 200 {
		t.Fatalf("match status = %d, body = %v", code, resp)
	}
	if matches, _ := resp["matches"].([]any); len(matches) != 0 {
		t.Fatalf("expected a discoverable searcher to never match themselves, got %v", matches)
	}
}

func TestMatchRequiresAuth(t *testing.T) {
	h := newHarness(t)
	code, _ := h.do(t, "POST", "/api/peard/contacts/match", "", map[string]any{"hashes": []string{}})
	if code != http.StatusUnauthorized && code != http.StatusForbidden {
		t.Fatalf("match without auth = %d, want 401 or 403", code)
	}
}

// A Sign in with Apple relay address is generated per app, per account, so it
// has never been anybody's address and cannot be in anybody's contacts.
// Matching on it is matching on a value nothing can produce.
func TestAppleRelayAddressesAreRecognised(t *testing.T) {
	for _, email := range []string{
		"abc123@privaterelay.appleid.com",
		"ABC123@PrivateRelay.AppleID.com",
		"  spaced@privaterelay.appleid.com  ",
	} {
		if !contacts.IsAppleRelayEmail(email) {
			t.Errorf("%q should be recognised as a relay address", email)
		}
	}
	for _, email := range []string{
		"someone@example.com",
		"someone@appleid.com",
		"privaterelay.appleid.com@example.com",
		"",
	} {
		if contacts.IsAppleRelayEmail(email) {
			t.Errorf("%q should not be a relay address", email)
		}
	}
}
