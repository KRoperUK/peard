package auth

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

const appleSignInPath = "/api/peard/auth/apple"

func signInBody(t *testing.T, token string) *strings.Reader {
	t.Helper()

	body, err := json.Marshal(map[string]string{"identity_token": token})
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	return strings.NewReader(string(body))
}

func signedInID(t testing.TB, res *http.Response) string {
	t.Helper()

	var out struct {
		Record struct {
			ID string `json:"id"`
		} `json:"record"`
	}
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return out.Record.ID
}

func newUser(t testing.TB, app core.App, email string, verified bool, password string) *core.Record {
	t.Helper()

	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("users collection: %v", err)
	}
	r := core.NewRecord(users)
	r.SetEmail(email)
	r.SetVerified(verified)
	r.SetPassword(password)
	if err := app.Save(r); err != nil {
		t.Fatalf("save user: %v", err)
	}
	return r
}

// Anyone can sign up with an email they do not own. When the owner later signs
// in with Apple they land in that account, so the password set by whoever made
// it has to stop working, and so do any sessions it already has.
func TestAppleSignInLocksOutAPrecreatedAccount(t *testing.T) {
	key := withTestIdentityKey(t)
	claims := identityClaims(time.Now().Add(10 * time.Minute))
	claims["email"] = "owner@example.com"
	var squatter *core.Record
	var squatterToken string

	scenario := tests.ApiScenario{
		Name:            "unverified account with a password",
		Method:          http.MethodPost,
		URL:             appleSignInPath,
		Body:            signInBody(t, signJWT(t, key, "test-kid", claims)),
		Headers:         map[string]string{"Content-Type": "application/json"},
		ExpectedStatus:  http.StatusOK,
		ExpectedContent: []string{`"token":`},
		TestAppFactory: func(tb testing.TB) *tests.TestApp {
			app := newIntegrationApp(tb)
			Register(app)
			squatter = newUser(tb, app, "owner@example.com", false, "squatter-pw-1")
			var err error
			if squatterToken, err = squatter.NewAuthToken(); err != nil {
				tb.Fatalf("token: %v", err)
			}
			return app
		},
		AfterTestFunc: func(tb testing.TB, app *tests.TestApp, res *http.Response) {
			if id := signedInID(tb, res); id != squatter.Id {
				tb.Fatalf("signed in as %q, want the existing account %q", id, squatter.Id)
			}
			user, err := app.FindRecordById("users", squatter.Id)
			if err != nil {
				tb.Fatalf("reload user: %v", err)
			}
			if user.ValidatePassword("squatter-pw-1") {
				tb.Error("the password set before Apple sign-in must no longer work")
			}
			if !user.Verified() {
				tb.Error("the account must be verified after Apple proves the email")
			}
			if _, err := app.FindAuthRecordByToken(squatterToken, core.TokenTypeAuth); err == nil {
				tb.Error("sessions from before Apple sign-in must stop validating")
			}
		},
	}
	scenario.Test(t)
}

// A verified account has already proved the email, so signing in with Apple
// links it and leaves its password alone.
func TestAppleSignInKeepsAVerifiedAccountsPassword(t *testing.T) {
	key := withTestIdentityKey(t)
	claims := identityClaims(time.Now().Add(10 * time.Minute))
	claims["email"] = "owner@example.com"
	var owner *core.Record

	scenario := tests.ApiScenario{
		Name:            "verified account",
		Method:          http.MethodPost,
		URL:             appleSignInPath,
		Body:            signInBody(t, signJWT(t, key, "test-kid", claims)),
		Headers:         map[string]string{"Content-Type": "application/json"},
		ExpectedStatus:  http.StatusOK,
		ExpectedContent: []string{`"token":`},
		TestAppFactory: func(tb testing.TB) *tests.TestApp {
			app := newIntegrationApp(tb)
			Register(app)
			owner = newUser(tb, app, "owner@example.com", true, "owner-pw-1")
			return app
		},
		AfterTestFunc: func(tb testing.TB, app *tests.TestApp, res *http.Response) {
			if id := signedInID(tb, res); id != owner.Id {
				tb.Fatalf("signed in as %q, want %q", id, owner.Id)
			}
			user, err := app.FindRecordById("users", owner.Id)
			if err != nil {
				tb.Fatalf("reload user: %v", err)
			}
			if !user.ValidatePassword("owner-pw-1") {
				tb.Error("a verified account's password must be left alone")
			}
		},
	}
	scenario.Test(t)
}

// Once linked, the Apple user id finds the account even when the token carries
// a different email, and an account that merely has that email is not used.
func TestAppleSignInPrefersTheLinkedAccount(t *testing.T) {
	key := withTestIdentityKey(t)
	claims := identityClaims(time.Now().Add(10 * time.Minute))
	claims["email"] = "someone-else@example.com"
	var linked, other *core.Record

	scenario := tests.ApiScenario{
		Name:            "linked by sub",
		Method:          http.MethodPost,
		URL:             appleSignInPath,
		Body:            signInBody(t, signJWT(t, key, "test-kid", claims)),
		Headers:         map[string]string{"Content-Type": "application/json"},
		ExpectedStatus:  http.StatusOK,
		ExpectedContent: []string{`"token":`},
		TestAppFactory: func(tb testing.TB) *tests.TestApp {
			app := newIntegrationApp(tb)
			Register(app)
			linked = newUser(tb, app, "original@example.com", true, "linked-pw-1")
			other = newUser(tb, app, "someone-else@example.com", false, "other-pw-1")
			linkAppleExternalAuth(app, linked, claims["sub"].(string))
			return app
		},
		AfterTestFunc: func(tb testing.TB, app *tests.TestApp, res *http.Response) {
			if id := signedInID(tb, res); id != linked.Id {
				tb.Fatalf("signed in as %q, want the linked account %q (not %q)", id, linked.Id, other.Id)
			}
		},
	}
	scenario.Test(t)
}
