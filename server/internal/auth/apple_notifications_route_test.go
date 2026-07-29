package auth

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

// Route-level tests: the unit tests cover verification and policy, the
// integration tests cover the database effects, and these cover the handler that
// joins them — the status codes and the status strings documented in
// docs/wire-contract.md. Apple retries on any non-2xx, so which failures answer
// 200 and which do not is part of the contract rather than an implementation
// detail.
//
// The signing key is swapped for a local one; everything else, including the
// HTTP layer and the real router, is production code.
func withTestKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	previous := appleNotificationKeyLookup
	appleNotificationKeyLookup = func(kid string) (*rsa.PublicKey, error) {
		if kid != "test-kid" {
			return nil, errNoKey
		}
		return &key.PublicKey, nil
	}
	t.Cleanup(func() { appleNotificationKeyLookup = previous })
	return key
}

func notificationBody(t *testing.T, key *rsa.PrivateKey, issuedAt time.Time, event map[string]any) *strings.Reader {
	t.Helper()

	token := signJWT(t, key, "test-kid", notificationClaims(t, issuedAt, event))
	body, err := json.Marshal(map[string]string{"payload": token})
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	return strings.NewReader(string(body))
}

// appFactory returns a TestApp with Pear'd's routes registered, so the scenario
// exercises the same binding main.go performs.
func appFactory(t testing.TB, seedSub string, out **fixture) func(testing.TB) *tests.TestApp {
	return func(testing.TB) *tests.TestApp {
		app := newIntegrationApp(t)
		Register(app)
		if seedSub != "" {
			*out = seed(t, app, seedSub)
		}
		return app
	}
}

func TestNotificationRouteRejectsMissingPayload(t *testing.T) {
	withTestKey(t)

	scenario := tests.ApiScenario{
		Name:            "no payload",
		Method:          http.MethodPost,
		URL:             appleNotificationPath,
		Body:            strings.NewReader(`{}`),
		Headers:         map[string]string{"Content-Type": "application/json"},
		ExpectedStatus:  http.StatusBadRequest,
		ExpectedContent: []string{`"status":400`},
		TestAppFactory:  appFactory(t, "", nil),
	}
	scenario.Test(t)
}

// A payload we cannot verify is the one case that must NOT answer 200: it did
// not come from Apple, and acknowledging it would hide the problem.
func TestNotificationRouteRejectsForgedPayload(t *testing.T) {
	withTestKey(t)
	attacker, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}

	scenario := tests.ApiScenario{
		Name:            "forged signature",
		Method:          http.MethodPost,
		URL:             appleNotificationPath,
		Body:            notificationBody(t, attacker, time.Now(), map[string]any{"type": eventConsentRevoked, "sub": "s"}),
		Headers:         map[string]string{"Content-Type": "application/json"},
		ExpectedStatus:  http.StatusUnauthorized,
		ExpectedContent: []string{`"status":401`},
		TestAppFactory:  appFactory(t, "", nil),
	}
	scenario.Test(t)
}

// consent-revoked, end to end over HTTP: 200 "applied", and the session is
// actually dead afterwards.
func TestNotificationRouteAppliesConsentRevoked(t *testing.T) {
	key := withTestKey(t)
	var f *fixture

	scenario := tests.ApiScenario{
		Name:            "consent revoked",
		Method:          http.MethodPost,
		URL:             appleNotificationPath,
		Body:            notificationBody(t, key, time.Now(), map[string]any{"type": eventConsentRevoked, "sub": "000123.route.0001"}),
		Headers:         map[string]string{"Content-Type": "application/json"},
		ExpectedStatus:  http.StatusOK,
		ExpectedContent: []string{`"status":"applied"`},
		TestAppFactory:  appFactory(t, "000123.route.0001", &f),
		AfterTestFunc: func(t testing.TB, app *tests.TestApp, res *http.Response) {
			if f == nil {
				t.Fatal("fixture was not seeded")
			}
			if _, err := app.FindAuthRecordByToken(f.authToken, core.TokenTypeAuth); err == nil {
				t.Error("the auth token must stop validating after the route runs")
			}
			devices, err := app.FindRecordsByFilter("devices", "user = {:u}", "", 0, 0, dbx.Params{"u": f.user.Id})
			if err != nil {
				t.Fatalf("query devices: %v", err)
			}
			if len(devices) != 0 {
				t.Errorf("devices remaining = %d, want 0", len(devices))
			}
		},
	}
	scenario.Test(t)
}

// A mail-forwarding change is acknowledged and changes nothing — the session has
// to survive, or a private-relay user would be signed out for turning off
// forwarding.
func TestNotificationRouteAcknowledgesEmailDisabled(t *testing.T) {
	key := withTestKey(t)
	var f *fixture

	scenario := tests.ApiScenario{
		Name:   "email disabled",
		Method: http.MethodPost,
		URL:    appleNotificationPath,
		Body: notificationBody(t, key, time.Now(), map[string]any{
			"type": eventEmailDisabled, "sub": "000123.route.0002",
			"email": "relay@privaterelay.appleid.com", "is_private_email": "true",
		}),
		Headers:         map[string]string{"Content-Type": "application/json"},
		ExpectedStatus:  http.StatusOK,
		ExpectedContent: []string{`"status":"acknowledged"`},
		TestAppFactory:  appFactory(t, "000123.route.0002", &f),
		AfterTestFunc: func(t testing.TB, app *tests.TestApp, res *http.Response) {
			if _, err := app.FindAuthRecordByToken(f.authToken, core.TokenTypeAuth); err != nil {
				t.Errorf("the session must survive a mail-forwarding change: %v", err)
			}
			devices, err := app.FindRecordsByFilter("devices", "user = {:u}", "", 0, 0, dbx.Params{"u": f.user.Id})
			if err != nil {
				t.Fatalf("query devices: %v", err)
			}
			if len(devices) != 1 {
				t.Errorf("devices = %d, want 1 (pushes must keep working)", len(devices))
			}
		},
	}
	scenario.Test(t)
}

// An event about somebody who never signed in here is acknowledged, not retried
// at us forever.
func TestNotificationRouteAcknowledgesUnknownUser(t *testing.T) {
	key := withTestKey(t)

	scenario := tests.ApiScenario{
		Name:            "unknown user",
		Method:          http.MethodPost,
		URL:             appleNotificationPath,
		Body:            notificationBody(t, key, time.Now(), map[string]any{"type": eventConsentRevoked, "sub": "000123.nobody.0001"}),
		Headers:         map[string]string{"Content-Type": "application/json"},
		ExpectedStatus:  http.StatusOK,
		ExpectedContent: []string{`"status":"acknowledged"`},
		TestAppFactory:  appFactory(t, "", nil),
	}
	scenario.Test(t)
}

// Verified as Apple's but unparsable: 200, because retrying the same bytes will
// never parse either.
func TestNotificationRouteAcknowledgesUnparsableEvents(t *testing.T) {
	key := withTestKey(t)
	claims := map[string]any{
		"iss":    appleIssuer,
		"aud":    "com.peard.app",
		"iat":    time.Now().Unix(),
		"jti":    "test-jti",
		"events": "{not json at all",
	}
	body, err := json.Marshal(map[string]string{"payload": signJWT(t, key, "test-kid", claims)})
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}

	scenario := tests.ApiScenario{
		Name:            "unparsable events",
		Method:          http.MethodPost,
		URL:             appleNotificationPath,
		Body:            strings.NewReader(string(body)),
		Headers:         map[string]string{"Content-Type": "application/json"},
		ExpectedStatus:  http.StatusOK,
		ExpectedContent: []string{`"status":"unparsable"`},
		TestAppFactory:  appFactory(t, "", nil),
	}
	scenario.Test(t)
}

// A stale capture replayed at the endpoint must be refused, which is the whole
// reason the iat window exists given there is no exp to rely on.
func TestNotificationRouteRejectsReplayedNotification(t *testing.T) {
	key := withTestKey(t)
	var f *fixture

	scenario := tests.ApiScenario{
		Name:   "replayed notification",
		Method: http.MethodPost,
		URL:    appleNotificationPath,
		Body: notificationBody(t, key, time.Now().Add(-notificationMaxAge-time.Hour),
			map[string]any{"type": eventConsentRevoked, "sub": "000123.route.0003"}),
		Headers:         map[string]string{"Content-Type": "application/json"},
		ExpectedStatus:  http.StatusUnauthorized,
		ExpectedContent: []string{`"status":401`},
		TestAppFactory:  appFactory(t, "000123.route.0003", &f),
		AfterTestFunc: func(t testing.TB, app *tests.TestApp, res *http.Response) {
			if _, err := app.FindAuthRecordByToken(f.authToken, core.TokenTypeAuth); err != nil {
				t.Errorf("a replayed notification must not have signed the user out: %v", err)
			}
		},
	}
	scenario.Test(t)
}
