package auth

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"peard/internal/profile"
)

// fakeApple stands in for appleid.apple.com's /auth/token and /auth/revoke,
// recording every form it receives.
type fakeApple struct {
	t      testing.TB
	key    *ecdsa.PublicKey
	status int

	mu    sync.Mutex
	calls []fakeAppleCall
}

type fakeAppleCall struct {
	path string
	form url.Values
}

// withFakeApple points the exchange and revocation at a local server and, when
// configure is true, sets the Sign in with Apple key settings to a freshly
// generated key the fake checks client secrets against.
func withFakeApple(t *testing.T, configure bool) *fakeApple {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	f := &fakeApple{t: t, key: &key.PublicKey, status: http.StatusOK}
	srv := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(srv.Close)

	previous := appleBaseURL
	appleBaseURL = srv.URL
	t.Cleanup(func() { appleBaseURL = previous })

	// Cleared either way, so a developer's own environment cannot leak in.
	t.Setenv("PEARD_APPLE_TEAM_ID", "")
	t.Setenv("PEARD_APPLE_KEY_ID", "")
	t.Setenv("PEARD_APPLE_PRIVATE_KEY", "")
	if configure {
		der, err := x509.MarshalPKCS8PrivateKey(key)
		if err != nil {
			t.Fatalf("marshal key: %v", err)
		}
		p8 := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
		t.Setenv("PEARD_APPLE_TEAM_ID", "TEAM123456")
		t.Setenv("PEARD_APPLE_KEY_ID", "KEY1234567")
		t.Setenv("PEARD_APPLE_PRIVATE_KEY", base64.StdEncoding.EncodeToString(p8))
	}
	return f
}

func (f *fakeApple) serve(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		f.t.Errorf("fake apple: parse form: %v", err)
	}
	f.mu.Lock()
	f.calls = append(f.calls, fakeAppleCall{path: r.URL.Path, form: r.PostForm})
	status := f.status
	f.mu.Unlock()

	f.checkClientSecret(r.PostForm)

	w.WriteHeader(status)
	if status != http.StatusOK {
		_, _ = w.Write([]byte(`{"error":"invalid_grant"}`))
		return
	}
	if r.URL.Path == "/auth/token" {
		_, _ = w.Write([]byte(`{"access_token":"a","token_type":"Bearer","expires_in":3600,"refresh_token":"refresh-from-apple","id_token":"i"}`))
	}
}

// checkClientSecret verifies the ES256 client secret the way Apple would.
func (f *fakeApple) checkClientSecret(form url.Values) {
	if got := form.Get("client_id"); got != "com.peard.app" {
		f.t.Errorf("client_id = %q, want the bundle id", got)
	}
	parts := strings.Split(form.Get("client_secret"), ".")
	if len(parts) != 3 {
		f.t.Errorf("client_secret is not a JWT: %q", form.Get("client_secret"))
		return
	}
	var header map[string]string
	raw, _ := base64.RawURLEncoding.DecodeString(parts[0])
	_ = json.Unmarshal(raw, &header)
	if header["alg"] != "ES256" || header["kid"] != "KEY1234567" {
		f.t.Errorf("client secret header = %v", header)
	}
	var claims map[string]any
	raw, _ = base64.RawURLEncoding.DecodeString(parts[1])
	_ = json.Unmarshal(raw, &claims)
	if claims["iss"] != "TEAM123456" || claims["sub"] != "com.peard.app" || claims["aud"] != appleIssuer {
		f.t.Errorf("client secret claims = %v", claims)
	}
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if len(sig) != 64 || !ecdsa.Verify(f.key, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		f.t.Error("client secret signature does not verify against the configured key")
	}
}

func (f *fakeApple) received() []fakeAppleCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]fakeAppleCall(nil), f.calls...)
}

// serve runs one request through the app's real router.
func serve(t *testing.T, app core.App, method, path, body, token string) *httptest.ResponseRecorder {
	t.Helper()
	router, err := apis.NewRouter(app)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}
	event := new(core.ServeEvent)
	event.App = app
	event.Router = router
	var mux http.Handler
	if err := app.OnServe().Trigger(event, func(e *core.ServeEvent) error {
		var err error
		mux, err = e.Router.BuildMux()
		return err
	}); err != nil {
		t.Fatalf("build mux: %v", err)
	}
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", token)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func storedAppleToken(t *testing.T, app core.App, userID string) string {
	t.Helper()
	row, err := app.FindFirstRecordByFilter(appleTokensCollection, "user = {:user}", dbx.Params{"user": userID})
	if err != nil {
		return ""
	}
	return row.GetString("refresh_token")
}

// appleSignIn posts a valid identity token, with code as the authorization
// code when it is not empty, and returns the response.
func appleSignIn(t *testing.T, app *tests.TestApp, code string) *httptest.ResponseRecorder {
	t.Helper()
	key := withTestIdentityKey(t)
	claims := identityClaims(time.Now().Add(10 * time.Minute))
	fields := map[string]string{"identity_token": signJWT(t, key, "test-kid", claims)}
	if code != "" {
		fields["authorization_code"] = code
	}
	body, _ := json.Marshal(fields)
	return serve(t, app, http.MethodPost, appleSignInPath, string(body), "")
}

func signedInUserID(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	if rec.Code != http.StatusOK {
		t.Fatalf("sign-in: status %d, body %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Record struct {
			ID string `json:"id"`
		} `json:"record"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil || out.Record.ID == "" {
		t.Fatalf("decode sign-in: %v; body %s", err, rec.Body.String())
	}
	return out.Record.ID
}

func TestAppleSignInExchangesTheCodeAndStoresTheRefreshToken(t *testing.T) {
	fake := withFakeApple(t, true)
	app := newIntegrationApp(t)
	Register(app)

	rec := appleSignIn(t, app, "one-time-code")
	userID := signedInUserID(t, rec)

	calls := fake.received()
	if len(calls) != 1 || calls[0].path != "/auth/token" {
		t.Fatalf("apple calls = %+v, want one /auth/token", calls)
	}
	if got := calls[0].form.Get("code"); got != "one-time-code" {
		t.Errorf("exchanged code = %q", got)
	}
	if got := calls[0].form.Get("grant_type"); got != "authorization_code" {
		t.Errorf("grant_type = %q", got)
	}
	if got := storedAppleToken(t, app, userID); got != "refresh-from-apple" {
		t.Errorf("stored refresh token = %q, want Apple's", got)
	}
	if strings.Contains(rec.Body.String(), "refresh-from-apple") {
		t.Error("the sign-in response carries the refresh token")
	}
}

func TestAppleSignInWithoutTheKeySkipsTheExchange(t *testing.T) {
	fake := withFakeApple(t, false)
	app := newIntegrationApp(t)
	Register(app)

	userID := signedInUserID(t, appleSignIn(t, app, "one-time-code"))

	if calls := fake.received(); len(calls) != 0 {
		t.Errorf("apple calls = %+v, want none without the key", calls)
	}
	if got := storedAppleToken(t, app, userID); got != "" {
		t.Errorf("stored refresh token = %q, want none", got)
	}
}

func TestAppleSignInSurvivesAFailedExchange(t *testing.T) {
	fake := withFakeApple(t, true)
	fake.status = http.StatusBadRequest
	app := newIntegrationApp(t)
	Register(app)

	userID := signedInUserID(t, appleSignIn(t, app, "stale-code"))

	if got := storedAppleToken(t, app, userID); got != "" {
		t.Errorf("stored refresh token = %q after Apple refused, want none", got)
	}
}

// deletionWorld is a signed-up user with a stored refresh token, and the
// account-deletion route wired up alongside auth's hooks.
func deletionWorld(t *testing.T) (*tests.TestApp, *core.Record, string) {
	t.Helper()
	app := newIntegrationApp(t)
	Register(app)
	profile.Register(app)

	user := newUser(t, app, "leaver@example.com", true, "leaver-pw-1")
	col, err := app.FindCollectionByNameOrId(appleTokensCollection)
	if err != nil {
		t.Fatalf("apple_tokens collection: %v", err)
	}
	row := core.NewRecord(col)
	row.Set("user", user.Id)
	row.Set("refresh_token", "stored-refresh-token")
	if err := app.Save(row); err != nil {
		t.Fatalf("save apple token: %v", err)
	}
	token, err := user.NewAuthToken()
	if err != nil {
		t.Fatalf("auth token: %v", err)
	}
	return app, user, token
}

func deleteAccount(t *testing.T, app *tests.TestApp, user *core.Record, token string) {
	t.Helper()
	rec := serve(t, app, http.MethodDelete, "/api/peard/account", "", token)
	if rec.Code != http.StatusOK {
		t.Fatalf("delete account: status %d, body %s", rec.Code, rec.Body.String())
	}
	if _, err := app.FindRecordById("users", user.Id); err == nil {
		t.Fatal("the account still exists after deletion")
	}
}

func TestAccountDeletionRevokesTheAppleToken(t *testing.T) {
	fake := withFakeApple(t, true)
	app, user, token := deletionWorld(t)

	deleteAccount(t, app, user, token)

	calls := fake.received()
	if len(calls) != 1 || calls[0].path != "/auth/revoke" {
		t.Fatalf("apple calls = %+v, want one /auth/revoke", calls)
	}
	if got := calls[0].form.Get("token"); got != "stored-refresh-token" {
		t.Errorf("revoked token = %q, want the stored one", got)
	}
	if got := calls[0].form.Get("token_type_hint"); got != "refresh_token" {
		t.Errorf("token_type_hint = %q", got)
	}
}

func TestAccountDeletionSurvivesAFailedRevocation(t *testing.T) {
	fake := withFakeApple(t, true)
	fake.status = http.StatusInternalServerError
	app, user, token := deletionWorld(t)

	deleteAccount(t, app, user, token)

	if calls := fake.received(); len(calls) != 1 {
		t.Errorf("apple calls = %+v, want the one failed revoke", calls)
	}
}

func TestAccountDeletionWithoutTheKeyStillDeletes(t *testing.T) {
	fake := withFakeApple(t, false)
	app, user, token := deletionWorld(t)

	deleteAccount(t, app, user, token)

	if calls := fake.received(); len(calls) != 0 {
		t.Errorf("apple calls = %+v, want none without the key", calls)
	}
}

// Apple has already revoked everything when it says consent was withdrawn, so
// the stored token is dropped without a call back to Apple.
func TestConsentRevokedDropsTheStoredToken(t *testing.T) {
	fake := withFakeApple(t, true)
	app, user, _ := deletionWorld(t)

	if err := applyNotificationAction(app, user, actionRevokeAccess); err != nil {
		t.Fatalf("apply: %v", err)
	}
	if got := storedAppleToken(t, app, user.Id); got != "" {
		t.Errorf("stored refresh token = %q after consent-revoked, want none", got)
	}
	if calls := fake.received(); len(calls) != 0 {
		t.Errorf("apple calls = %+v, want none", calls)
	}
}

func TestParseAppleKeyAcceptsBase64OrPEM(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	p8 := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))

	for name, raw := range map[string]string{
		"base64": base64.StdEncoding.EncodeToString([]byte(p8)),
		"pem":    p8,
	} {
		if _, err := parseAppleKey(raw); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := parseAppleKey("not a key"); err == nil {
		t.Error("garbage parsed as a key")
	}
}
