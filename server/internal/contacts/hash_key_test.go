package contacts_test

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"testing"

	"github.com/pocketbase/pocketbase/core"

	"peard/internal/contacts"
)

const testHashKey = "test-contact-hash-key"

// keyedWith is what the server should store for a plain client hash under key.
func keyedWith(key, digest string) string {
	mac := hmac.New(sha256.New, []byte(key))
	mac.Write([]byte(digest))
	return hex.EncodeToString(mac.Sum(nil))
}

// boot runs the app's bootstrap hooks again, which is when the server re-keys.
func (h *harness) boot(t *testing.T) {
	t.Helper()
	if err := h.app.OnBootstrap().Trigger(&core.BootstrapEvent{App: h.app}, func(*core.BootstrapEvent) error {
		return nil
	}); err != nil {
		t.Fatalf("bootstrap: %v", err)
	}
}

func (h *harness) reload(t *testing.T, id string) *core.Record {
	t.Helper()
	r, err := h.app.FindRecordById("users", id)
	if err != nil {
		t.Fatalf("reload %s: %v", id, err)
	}
	return r
}

// discoverableWithPhone opts a user in with a phone number, through the same
// settings route the app uses.
func (h *harness) discoverableWithPhone(t *testing.T, token, phone string) {
	t.Helper()
	code, resp := h.do(t, "POST", "/api/peard/contacts/settings", token, map[string]any{
		"discoverable": true, "phone": phone,
	})
	if code != 200 {
		t.Fatalf("settings status = %d, body = %v", code, resp)
	}
}

// matchOne posts hashes as the searcher and returns the single match.
func (h *harness) matchOne(t *testing.T, token string, hashes ...string) map[string]any {
	t.Helper()
	code, resp := h.do(t, "POST", "/api/peard/contacts/match", token, map[string]any{"hashes": hashes})
	if code != 200 {
		t.Fatalf("match status = %d, body = %v", code, resp)
	}
	matches, _ := resp["matches"].([]any)
	if len(matches) != 1 {
		t.Fatalf("matches = %v, want exactly one", matches)
	}
	match, _ := matches[0].(map[string]any)
	return match
}

func TestKeyedHashesAreStoredKeyedAndStillMatch(t *testing.T) {
	t.Setenv("PEARD_CONTACT_HASH_KEY", testHashKey)
	h := newHarness(t)
	alex, alexToken := h.newUser(t, "alex@example.com")
	_, searcherToken := h.newUser(t, "searcher@example.com")
	h.discoverableWithPhone(t, alexToken, "+44 7888 291038")

	stored := h.reload(t, alex.Id)
	plainEmail, plainPhone := contacts.HashEmail("alex@example.com"), contacts.HashPhone("+44 7888 291038")
	if got := stored.GetString("email_hash"); got == plainEmail || got != keyedWith(testHashKey, plainEmail) {
		t.Errorf("email_hash = %q, want HMAC(key, sha256) rather than the plain %q", got, plainEmail)
	}
	if got := stored.GetString("phone_hash"); got == plainPhone || got != keyedWith(testHashKey, plainPhone) {
		t.Errorf("phone_hash = %q, want HMAC(key, sha256) rather than the plain %q", got, plainPhone)
	}

	// The app still sends plain SHA-256, and must still find alex by either.
	for what, submitted := range map[string]string{"email": plainEmail, "phone": plainPhone} {
		match := h.matchOne(t, searcherToken, contacts.HashEmail("nobody@example.com"), submitted)
		if match["id"] != alex.Id {
			t.Errorf("by %s: matched %v, want alex", what, match["id"])
		}
		// The echo is the caller's own hash, not the stored keyed one, which
		// the app could not map back to a contact.
		if match["hash"] != submitted {
			t.Errorf("by %s: echoed hash %v, want the submitted %q", what, match["hash"], submitted)
		}
	}
}

func TestBootReKeysExistingAccountsWhenTheKeyIsAddedOrChanged(t *testing.T) {
	t.Setenv("PEARD_CONTACT_HASH_KEY", "")
	h := newHarness(t)
	alex, alexToken := h.newUser(t, "alex@example.com")
	_, searcherToken := h.newUser(t, "searcher@example.com")
	h.discoverableWithPhone(t, alexToken, "+1 555 010 2000")
	plainEmail, plainPhone := contacts.HashEmail("alex@example.com"), contacts.HashPhone("+1 555 010 2000")
	before := h.reload(t, alex.Id).GetString("updated")

	for _, key := range []string{"first-key", "rotated-key"} {
		t.Setenv("PEARD_CONTACT_HASH_KEY", key)
		h.boot(t)

		stored := h.reload(t, alex.Id)
		if got := stored.GetString("email_hash"); got != keyedWith(key, plainEmail) {
			t.Errorf("key %q: email_hash = %q, want it re-keyed", key, got)
		}
		if got := stored.GetString("phone_hash"); got != keyedWith(key, plainPhone) {
			t.Errorf("key %q: phone_hash = %q, want it re-keyed", key, got)
		}
		if match := h.matchOne(t, searcherToken, plainEmail); match["id"] != alex.Id {
			t.Errorf("key %q: matched %v after re-key, want alex", key, match["id"])
		}
		// Derived columns only: re-keying is not an edit to the account.
		if got := stored.GetString("updated"); got != before {
			t.Errorf("key %q: updated moved from %s to %s", key, before, got)
		}
	}

	// Taking the key away puts the plain hashes back, so matching carries on.
	t.Setenv("PEARD_CONTACT_HASH_KEY", "")
	h.boot(t)
	if got := h.reload(t, alex.Id).GetString("email_hash"); got != plainEmail {
		t.Errorf("without a key: email_hash = %q, want the plain %q", got, plainEmail)
	}
}

func TestWithoutAKeyHashesArePlainSHA256(t *testing.T) {
	t.Setenv("PEARD_CONTACT_HASH_KEY", "")
	h := newHarness(t)
	alex, alexToken := h.newUser(t, "alex@example.com")
	_, searcherToken := h.newUser(t, "searcher@example.com")
	h.discoverableWithPhone(t, alexToken, "+1 555 010 2000")
	h.boot(t)

	stored := h.reload(t, alex.Id)
	if got := stored.GetString("email_hash"); got != contacts.HashEmail("alex@example.com") {
		t.Errorf("email_hash = %q, want plain SHA-256", got)
	}
	if got := stored.GetString("phone_hash"); got != contacts.HashPhone("+1 555 010 2000") {
		t.Errorf("phone_hash = %q, want plain SHA-256", got)
	}
	match := h.matchOne(t, searcherToken, contacts.HashEmail("alex@example.com"))
	if match["id"] != alex.Id || match["hash"] != contacts.HashEmail("alex@example.com") {
		t.Errorf("match = %v, want alex with the submitted hash", match)
	}
}
