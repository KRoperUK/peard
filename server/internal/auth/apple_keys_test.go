package auth

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// Apple's signing keys rotate, and the cache must follow: a token signed with
// a newly published key verifies without restarting the server (#439). The
// key set below changes under the cache the way Apple's does.
type mutableJWKS struct {
	mu   sync.Mutex
	keys map[string]*rsa.PublicKey
	hits int
}

func (m *mutableJWKS) serve(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m.mu.Lock()
		defer m.mu.Unlock()
		m.hits++
		doc := map[string]any{"keys": []any{}}
		list := []any{}
		for kid, pub := range m.keys {
			e := big.NewInt(int64(pub.E)).Bytes()
			list = append(list, map[string]any{
				"kty": "RSA",
				"kid": kid,
				"use": "sig",
				"alg": "RS256",
				"n":   base64.RawURLEncoding.EncodeToString(pub.N.Bytes()),
				"e":   base64.RawURLEncoding.EncodeToString(e),
			})
		}
		doc["keys"] = list
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(doc); err != nil {
			t.Errorf("serve JWKS: %v", err)
		}
	}))
}

func (m *mutableJWKS) set(keys map[string]*rsa.PublicKey) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.keys = keys
}

func (m *mutableJWKS) fetches() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.hits
}

func withKeyServer(t *testing.T, keys map[string]*rsa.PublicKey) *mutableJWKS {
	t.Helper()
	m := &mutableJWKS{keys: keys}
	srv := m.serve(t)
	t.Cleanup(srv.Close)

	previousURL, previousCache, previousCached := appleJWKSURL, keysCache, keysCached
	appleJWKSURL = srv.URL
	keysCache = nil
	keysCached = time.Time{}
	t.Cleanup(func() {
		appleJWKSURL, keysCache, keysCached = previousURL, previousCache, previousCached
	})
	return m
}

func testRSAKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	return key
}

// A token signed with a newly published key verifies: the unknown kid
// triggers a refetch rather than failing against the stale cache.
func TestUnknownKidRefetchesTheKeySet(t *testing.T) {
	oldKey := testRSAKey(t)
	m := withKeyServer(t, map[string]*rsa.PublicKey{"old": &oldKey.PublicKey})

	first := signJWT(t, oldKey, "old", identityClaims(time.Now().Add(10*time.Minute)))
	if _, err := verifyIdentityToken(first, "com.peard.app", ""); err != nil {
		t.Fatalf("token on the cached key: %v", err)
	}

	newKey := testRSAKey(t)
	m.set(map[string]*rsa.PublicKey{"new": &newKey.PublicKey})
	rotated := signJWT(t, newKey, "new", identityClaims(time.Now().Add(10*time.Minute)))
	if _, err := verifyIdentityToken(rotated, "com.peard.app", ""); err != nil {
		t.Fatalf("token on the rotated key: %v", err)
	}
	if m.fetches() != 2 {
		t.Errorf("key set fetched %d times, want 2 (prime + rotation refetch)", m.fetches())
	}
}

// A refetch that fails must not reject a token whose key is still in the
// cache: the stale set stays authoritative until a new one arrives.
func TestFailedRefetchKeepsServingCachedKeys(t *testing.T) {
	key := testRSAKey(t)
	m := withKeyServer(t, map[string]*rsa.PublicKey{"only": &key.PublicKey})

	token := signJWT(t, key, "only", identityClaims(time.Now().Add(10*time.Minute)))
	if _, err := verifyIdentityToken(token, "com.peard.app", ""); err != nil {
		t.Fatalf("priming token: %v", err)
	}

	// The cache expires and Apple goes away at once.
	keysMu.Lock()
	keysCached = time.Now().Add(-25 * time.Hour)
	keysMu.Unlock()
	appleJWKSURL = "http://127.0.0.1:9/unreachable"

	if _, err := verifyIdentityToken(token, "com.peard.app", ""); err != nil {
		t.Errorf("token on a cached key with Apple unreachable: %v", err)
	}
	if m.fetches() != 1 {
		t.Errorf("key set fetched %d times, want 1 (the prime; the refetch failed)", m.fetches())
	}
}

// …while a kid no key set holds still fails, cleanly.
func TestUnknownKidFailsCleanly(t *testing.T) {
	key := testRSAKey(t)
	withKeyServer(t, map[string]*rsa.PublicKey{"only": &key.PublicKey})

	if _, err := applePublicKey("nope"); err == nil {
		t.Fatal("an unknown kid must fail")
	} else if !strings.Contains(err.Error(), "no matching Apple key") {
		t.Errorf("error = %q, want a clean no-matching-key failure", err)
	}
}
