package auth

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
	"time"
)

// verifyIdentityToken and verifyNotificationToken were split apart to share one
// signature check without sharing a claim set. Sign-in is the path that cannot be
// exercised on a simulator or by curl — it needs a real Apple authorization — so
// these tests stand in for that, exercising the same function the route calls
// with only the key source swapped.

func withTestIdentityKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	previous := appleIdentityKeyLookup
	appleIdentityKeyLookup = func(kid string) (*rsa.PublicKey, error) {
		if kid != "test-kid" {
			return nil, errNoKey
		}
		return &key.PublicKey, nil
	}
	t.Cleanup(func() { appleIdentityKeyLookup = previous })
	return key
}

func identityClaims(expires time.Time) map[string]any {
	return map[string]any{
		"iss":            appleIssuer,
		"aud":            "com.peard.app",
		"sub":            "000123.identity.0001",
		"iat":            time.Now().Unix(),
		"exp":            expires.Unix(),
		"email":          "user@privaterelay.appleid.com",
		"email_verified": "true",
	}
}

// The happy path, including the email_verified string Apple actually sends.
func TestVerifyIdentityTokenAcceptsValidToken(t *testing.T) {
	key := withTestIdentityKey(t)
	token := signJWT(t, key, "test-kid", identityClaims(time.Now().Add(10*time.Minute)))

	claims, err := verifyIdentityToken(token, "com.peard.app", "")
	if err != nil {
		t.Fatalf("verifyIdentityToken: %v", err)
	}
	if claims.Subject != "000123.identity.0001" {
		t.Errorf("sub = %q", claims.Subject)
	}
	if claims.Email != "user@privaterelay.appleid.com" {
		t.Errorf("email = %q", claims.Email)
	}
	if !claimVerified(claims.EmailVerified) {
		t.Error("email_verified should read as true from the string \"true\"")
	}
}

// Unlike a notification, an identity token has an exp and it must be enforced —
// the refactor must not have dropped this check.
func TestVerifyIdentityTokenRejectsExpired(t *testing.T) {
	key := withTestIdentityKey(t)

	expired := signJWT(t, key, "test-kid", identityClaims(time.Now().Add(-10*time.Minute)))
	if _, err := verifyIdentityToken(expired, "com.peard.app", ""); err == nil {
		t.Error("an expired identity token must be rejected")
	}

	// Inside the 5 min skew allowance it is still accepted.
	borderline := signJWT(t, key, "test-kid", identityClaims(time.Now().Add(-2*time.Minute)))
	if _, err := verifyIdentityToken(borderline, "com.peard.app", ""); err != nil {
		t.Errorf("a token expired within the skew allowance must be accepted: %v", err)
	}
}

func TestVerifyIdentityTokenRejectsForeignSignature(t *testing.T) {
	withTestIdentityKey(t)
	attacker, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}

	token := signJWT(t, attacker, "test-kid", identityClaims(time.Now().Add(10*time.Minute)))
	if _, err := verifyIdentityToken(token, "com.peard.app", ""); err == nil {
		t.Fatal("a token signed by another key must not verify")
	}
}

func TestVerifyIdentityTokenRejectsWrongAudience(t *testing.T) {
	key := withTestIdentityKey(t)
	token := signJWT(t, key, "test-kid", identityClaims(time.Now().Add(10*time.Minute)))

	if _, err := verifyIdentityToken(token, "com.other.app", ""); err == nil {
		t.Fatal("wrong audience must be rejected")
	}
}

// The client hashes the nonce before handing it to Apple, and Apple echoes the
// hash. Both forms are accepted because clients differ; a mismatch is not.
func TestVerifyIdentityTokenNonceHandling(t *testing.T) {
	key := withTestIdentityKey(t)
	raw := "a-raw-nonce-value"
	sum := sha256.Sum256([]byte(raw))
	hashed := hex.EncodeToString(sum[:])

	hashedClaims := identityClaims(time.Now().Add(10 * time.Minute))
	hashedClaims["nonce"] = hashed
	if _, err := verifyIdentityToken(signJWT(t, key, "test-kid", hashedClaims), "com.peard.app", raw); err != nil {
		t.Errorf("hashed nonce should verify: %v", err)
	}

	// The comparison is case-insensitive, so upper-case hex is the same value.
	upperClaims := identityClaims(time.Now().Add(10 * time.Minute))
	upperClaims["nonce"] = strings.ToUpper(hashed)
	if _, err := verifyIdentityToken(signJWT(t, key, "test-kid", upperClaims), "com.peard.app", raw); err != nil {
		t.Errorf("upper-case hex nonce should verify: %v", err)
	}

	// Some clients pass the raw value straight through instead of hashing it.
	rawClaims := identityClaims(time.Now().Add(10 * time.Minute))
	rawClaims["nonce"] = raw
	if _, err := verifyIdentityToken(signJWT(t, key, "test-kid", rawClaims), "com.peard.app", raw); err != nil {
		t.Errorf("raw nonce should also verify: %v", err)
	}

	wrongClaims := identityClaims(time.Now().Add(10 * time.Minute))
	wrongClaims["nonce"] = "somebody-elses-nonce"
	if _, err := verifyIdentityToken(signJWT(t, key, "test-kid", wrongClaims), "com.peard.app", raw); err == nil {
		t.Error("a nonce that matches neither form must be rejected")
	}
}
