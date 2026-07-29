package auth

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// signJWT produces a real RS256 JWT so the tests exercise the same code path
// production does — header parsing, key lookup, signature check, claim decode —
// with only the key source swapped. Nothing here is stubbed past the network.
func signJWT(t *testing.T, key *rsa.PrivateKey, kid string, claims map[string]any) string {
	t.Helper()

	header, err := json.Marshal(map[string]any{"alg": "RS256", "kid": kid, "typ": "JWT"})
	if err != nil {
		t.Fatalf("marshal header: %v", err)
	}
	payload, err := json.Marshal(claims)
	if err != nil {
		t.Fatalf("marshal claims: %v", err)
	}

	signing := base64.RawURLEncoding.EncodeToString(header) + "." +
		base64.RawURLEncoding.EncodeToString(payload)
	digest := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func testKey(t *testing.T) (*rsa.PrivateKey, keyLookup) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	return key, func(kid string) (*rsa.PublicKey, error) {
		if kid != "test-kid" {
			return nil, errNoKey
		}
		return &key.PublicKey, nil
	}
}

var errNoKey = &noKeyError{}

type noKeyError struct{}

func (*noKeyError) Error() string { return "no matching key" }

// eventsString mimics Apple's encoding: `events` is a string whose contents are
// JSON, so the payload is doubly encoded.
func eventsString(t *testing.T, event map[string]any) string {
	t.Helper()
	b, err := json.Marshal(event)
	if err != nil {
		t.Fatalf("marshal event: %v", err)
	}
	return string(b)
}

func notificationClaims(t *testing.T, issuedAt time.Time, event map[string]any) map[string]any {
	t.Helper()
	return map[string]any{
		"iss":    appleIssuer,
		"aud":    "com.peard.app",
		"iat":    issuedAt.Unix(),
		"jti":    "test-jti",
		"events": eventsString(t, event),
	}
}

// A well-formed, freshly issued notification verifies and its event parses.
func TestVerifyNotificationTokenAcceptsFreshToken(t *testing.T) {
	key, lookup := testKey(t)
	now := time.Now()
	token := signJWT(t, key, "test-kid", notificationClaims(t, now, map[string]any{
		"type":             eventConsentRevoked,
		"sub":              "000123.abc.0001",
		"event_time":       now.UnixMilli(),
		"is_private_email": "true",
	}))

	claims, err := verifyNotificationToken(token, "com.peard.app", now, lookup)
	if err != nil {
		t.Fatalf("verifyNotificationToken: %v", err)
	}
	if claims.JTI != "test-jti" {
		t.Errorf("jti = %q, want %q", claims.JTI, "test-jti")
	}

	event, err := parseNotificationEvent(claims.Events)
	if err != nil {
		t.Fatalf("parseNotificationEvent: %v", err)
	}
	if event.Type != eventConsentRevoked {
		t.Errorf("type = %q, want %q", event.Type, eventConsentRevoked)
	}
	if event.Subject != "000123.abc.0001" {
		t.Errorf("sub = %q", event.Subject)
	}
	if !claimVerified(event.IsPrivateEmail) {
		t.Error("is_private_email should read as true from the string \"true\"")
	}
}

// The signature must actually be checked: a token signed by a different key,
// with every claim correct, has to fail.
func TestVerifyNotificationTokenRejectsForeignSignature(t *testing.T) {
	_, lookup := testKey(t)
	attacker, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	now := time.Now()
	token := signJWT(t, attacker, "test-kid", notificationClaims(t, now, map[string]any{
		"type": eventAccountDelete,
		"sub":  "000123.abc.0001",
	}))

	if _, err := verifyNotificationToken(token, "com.peard.app", now, lookup); err == nil {
		t.Fatal("a token signed by another key must not verify")
	}
}

// An unsigned "alg: none" token must be refused outright rather than treated as
// having an empty signature.
func TestVerifyNotificationTokenRejectsAlgNone(t *testing.T) {
	_, lookup := testKey(t)
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none","kid":"test-kid"}`))
	payload := base64.RawURLEncoding.EncodeToString([]byte(`{"iss":"` + appleIssuer + `","aud":"com.peard.app"}`))

	if _, err := verifyNotificationToken(header+"."+payload+".", "com.peard.app", time.Now(), lookup); err == nil {
		t.Fatal("alg=none must be rejected")
	}
}

func TestVerifyNotificationTokenRejectsWrongIssuerAndAudience(t *testing.T) {
	key, lookup := testKey(t)
	now := time.Now()
	event := map[string]any{"type": eventConsentRevoked, "sub": "s"}

	claims := notificationClaims(t, now, event)
	claims["iss"] = "https://evil.example.com"
	if _, err := verifyNotificationToken(signJWT(t, key, "test-kid", claims), "com.peard.app", now, lookup); err == nil {
		t.Error("wrong issuer must be rejected")
	}

	// The audience is the bundle id. A notification meant for a different app
	// signed by the same Apple key must not act on our users.
	fresh := notificationClaims(t, now, event)
	if _, err := verifyNotificationToken(signJWT(t, key, "test-kid", fresh), "com.other.app", now, lookup); err == nil {
		t.Error("wrong audience must be rejected")
	}
}

// The freshness window is the only thing standing in for a missing `exp`, so it
// carries real weight: a captured notification replayed later must stop working.
func TestVerifyNotificationTokenBoundsReplayWindow(t *testing.T) {
	key, lookup := testKey(t)
	now := time.Now()
	event := map[string]any{"type": eventConsentRevoked, "sub": "s"}

	stale := signJWT(t, key, "test-kid", notificationClaims(t, now.Add(-notificationMaxAge-time.Minute), event))
	if _, err := verifyNotificationToken(stale, "com.peard.app", now, lookup); err == nil {
		t.Error("a notification older than the replay window must be rejected")
	}

	// Just inside the window still works, so Apple's retries are not lost.
	recent := signJWT(t, key, "test-kid", notificationClaims(t, now.Add(-notificationMaxAge+time.Minute), event))
	if _, err := verifyNotificationToken(recent, "com.peard.app", now, lookup); err != nil {
		t.Errorf("a notification inside the window must be accepted: %v", err)
	}

	future := signJWT(t, key, "test-kid", notificationClaims(t, now.Add(time.Hour), event))
	if _, err := verifyNotificationToken(future, "com.peard.app", now, lookup); err == nil {
		t.Error("an iat in the future must be rejected")
	}

	// Small clock disagreement is tolerated in that direction.
	skewed := signJWT(t, key, "test-kid", notificationClaims(t, now.Add(notificationClockSkew-time.Second), event))
	if _, err := verifyNotificationToken(skewed, "com.peard.app", now, lookup); err != nil {
		t.Errorf("iat within the skew allowance must be accepted: %v", err)
	}
}

func TestVerifyNotificationTokenRequiresIat(t *testing.T) {
	key, lookup := testKey(t)
	claims := notificationClaims(t, time.Now(), map[string]any{"type": eventConsentRevoked})
	delete(claims, "iat")

	if _, err := verifyNotificationToken(signJWT(t, key, "test-kid", claims), "com.peard.app", time.Now(), lookup); err == nil {
		t.Fatal("a token with no iat has no freshness bound and must be rejected")
	}
}

// Apple sends `events` as a string holding JSON. Accepting a bare object too
// means a change on their side does not break the endpoint.
func TestParseNotificationEventAcceptsBothEncodings(t *testing.T) {
	inner := `{"type":"email-disabled","sub":"000123.abc","email":"relay@privaterelay.appleid.com","is_private_email":true}`

	quoted, err := json.Marshal(inner)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	fromString, err := parseNotificationEvent(quoted)
	if err != nil {
		t.Fatalf("string form: %v", err)
	}
	fromObject, err := parseNotificationEvent([]byte(inner))
	if err != nil {
		t.Fatalf("object form: %v", err)
	}

	for _, got := range []*appleNotificationEvent{fromString, fromObject} {
		if got.Type != eventEmailDisabled {
			t.Errorf("type = %q, want %q", got.Type, eventEmailDisabled)
		}
		if got.Email != "relay@privaterelay.appleid.com" {
			t.Errorf("email = %q", got.Email)
		}
		if !claimVerified(got.IsPrivateEmail) {
			t.Error("is_private_email should read as true from the bool true")
		}
	}
}

func TestParseNotificationEventRejectsUnusableClaims(t *testing.T) {
	cases := map[string]string{
		"absent":       ``,
		"null":         `null`,
		"empty string": `""`,
		"no type":      `{"sub":"000123.abc"}`,
		"not json":     `"{oh dear"`,
	}
	for name, raw := range cases {
		if _, err := parseNotificationEvent(json.RawMessage(raw)); err == nil {
			t.Errorf("%s: expected an error, got none", name)
		}
	}
}

// The action table is the whole policy, so it is asserted directly.
func TestActionFor(t *testing.T) {
	cases := []struct {
		eventType string
		erase     bool
		want      notificationAction
		known     bool
	}{
		// No email is sent by this server, so forwarding changes are recorded
		// and nothing else.
		{eventEmailDisabled, false, actionRecord, true},
		{eventEmailEnabled, false, actionRecord, true},
		{eventEmailDisabled, true, actionRecord, true},

		{eventConsentRevoked, false, actionRevokeAccess, true},
		// Opting in to erasure must not turn a revocation into a deletion.
		{eventConsentRevoked, true, actionRevokeAccess, true},

		// The default for a deleted Apple Account is revoke-not-erase, because
		// deleting the user cascades their moments out of other people's
		// shared timelines.
		{eventAccountDelete, false, actionRevokeAccess, true},
		{eventAccountDelete, true, actionErase, true},

		// An event type Apple adds later is acknowledged, never acted on.
		{"some-future-event", true, actionRecord, false},
		{"", true, actionRecord, false},
	}

	for _, c := range cases {
		got, known := actionFor(c.eventType, c.erase)
		if got != c.want || known != c.known {
			t.Errorf("actionFor(%q, erase=%v) = (%v, %v), want (%v, %v)",
				c.eventType, c.erase, got, known, c.want, c.known)
		}
	}
}

// The erasure switch is opt-in and must only respond to an explicit "true".
func TestEraseOnAccountDeleteDefaultsOff(t *testing.T) {
	t.Setenv("PEARD_APPLE_ERASE_ON_ACCOUNT_DELETE", "")
	if eraseOnAccountDelete() {
		t.Error("unset must mean off")
	}
	for _, v := range []string{"false", "0", "yes", "1", "TRUE ", " true"} {
		t.Setenv("PEARD_APPLE_ERASE_ON_ACCOUNT_DELETE", v)
		want := strings.EqualFold(strings.TrimSpace(v), "true")
		if got := eraseOnAccountDelete(); got != want {
			t.Errorf("value %q: got %v, want %v", v, got, want)
		}
	}
}

func TestAppleAudienceDefault(t *testing.T) {
	t.Setenv("PEARD_APPLE_AUDIENCE", "")
	if got := appleAudience(); got != "com.peard.app" {
		t.Errorf("default audience = %q, want com.peard.app", got)
	}
	t.Setenv("PEARD_APPLE_AUDIENCE", "com.example.other")
	if got := appleAudience(); got != "com.example.other" {
		t.Errorf("override audience = %q", got)
	}
}

// The identity token and the notification token share a signature check but not
// a claim set. This is the regression that matters: an identity token requires
// `exp`, and folding both into one validator would reject every notification,
// since Apple sends none.
func TestNotificationTokenHasNoExpAndStillVerifies(t *testing.T) {
	key, lookup := testKey(t)
	now := time.Now()
	claims := notificationClaims(t, now, map[string]any{"type": eventConsentRevoked, "sub": "s"})
	if _, ok := claims["exp"]; ok {
		t.Fatal("fixture should not carry exp")
	}

	if _, err := verifyNotificationToken(signJWT(t, key, "test-kid", claims), "com.peard.app", now, lookup); err != nil {
		t.Fatalf("a notification with no exp must verify: %v", err)
	}
}
