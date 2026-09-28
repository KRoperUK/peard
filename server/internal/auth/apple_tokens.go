package auth

// Sign in with Apple token revocation (App Store guideline 5.1.1(v)).
//
// An app that offers Sign in with Apple must revoke the user's Apple tokens when
// they delete their account, and revoking needs a token to revoke. The identity
// token the app sends at sign-in is not one: Apple's /auth/revoke takes a
// refresh or access token, and those come only from exchanging the one-time
// authorization code, which the app now sends alongside the identity token.
//
// So, at sign-in: exchange the code at /auth/token and keep the refresh token.
// On account deletion: send it to /auth/revoke. Both calls authenticate with a
// client secret — an ES256 JWT signed with the team's Sign in with Apple key —
// built here with the standard library, like the rest of this package's JWT
// handling.
//
// Neither step may cost the user anything. With the key unconfigured, or with
// Apple slow or refusing, sign-in still signs in and deletion still deletes:
// the failure is logged and that is all. A sign-in blocked by an optional
// compliance call would be a worse outcome than the missing revocation.
//
// The refresh token lives in `apple_tokens` (migration 1786924800), a
// collection with no API rules, so only a superuser can read it. It is not
// encrypted at rest: on its own it is useless, because every call that accepts
// it also demands a client secret signed with the private key, and that key is
// in the server's environment, not its database.

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

const appleTokensCollection = "apple_tokens"

// appleBaseURL is where the token exchange and revocation are sent. A variable
// solely so tests can point it at an httptest server; nothing in production
// reassigns it, and there is deliberately no setting to redirect a client
// secret elsewhere.
var appleBaseURL = appleIssuer

// appleClient is the configuration the client secret needs.
type appleClient struct {
	teamID, keyID, clientID string
	key                     *ecdsa.PrivateKey
}

// errAppleClientUnconfigured means none of the Sign in with Apple key settings
// are present: a normal state for a development server, not a fault.
var errAppleClientUnconfigured = errors.New("sign in with apple key not configured")

// loadAppleClient reads the key settings from the environment on every call,
// so a key added to a running deployment's environment takes effect at the
// next restart without anything cached going stale.
func loadAppleClient() (*appleClient, error) {
	teamID := strings.TrimSpace(os.Getenv("PEARD_APPLE_TEAM_ID"))
	keyID := strings.TrimSpace(os.Getenv("PEARD_APPLE_KEY_ID"))
	rawKey := strings.TrimSpace(os.Getenv("PEARD_APPLE_PRIVATE_KEY"))
	if teamID == "" && keyID == "" && rawKey == "" {
		return nil, errAppleClientUnconfigured
	}
	if teamID == "" || keyID == "" || rawKey == "" {
		return nil, errors.New("PEARD_APPLE_TEAM_ID, PEARD_APPLE_KEY_ID and PEARD_APPLE_PRIVATE_KEY must all be set")
	}
	key, err := parseAppleKey(rawKey)
	if err != nil {
		return nil, err
	}
	return &appleClient{teamID: teamID, keyID: keyID, clientID: appleAudience(), key: key}, nil
}

// parseAppleKey accepts the .p8 file base64-encoded, which survives being put
// in an environment variable, or its PEM text as-is.
func parseAppleKey(raw string) (*ecdsa.PrivateKey, error) {
	pemBytes := []byte(raw)
	if !strings.HasPrefix(raw, "-----BEGIN") {
		decoded, err := base64.StdEncoding.DecodeString(raw)
		if err != nil {
			return nil, fmt.Errorf("PEARD_APPLE_PRIVATE_KEY is not base64: %w", err)
		}
		pemBytes = decoded
	}
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("PEARD_APPLE_PRIVATE_KEY holds no PEM block")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse PEARD_APPLE_PRIVATE_KEY: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("PEARD_APPLE_PRIVATE_KEY is not an EC key")
	}
	return key, nil
}

// clientSecret signs the short-lived JWT Apple takes in place of a password.
// Apple allows up to six months; five minutes is plenty for one request and
// makes a leaked secret nearly worthless.
func (c *appleClient) clientSecret(now time.Time) (string, error) {
	header, err := json.Marshal(map[string]string{"alg": "ES256", "kid": c.keyID})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{
		"iss": c.teamID,
		"iat": now.Unix(),
		"exp": now.Add(5 * time.Minute).Unix(),
		"aud": appleIssuer,
		"sub": c.clientID,
	})
	if err != nil {
		return "", err
	}
	signing := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, c.key, digest[:])
	if err != nil {
		return "", err
	}
	// JWS wants r and s as fixed-width big-endian halves, not ASN.1 DER.
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

// post sends a client-authenticated form to one of Apple's /auth endpoints and
// returns the body of a 200.
func (c *appleClient) post(path string, form url.Values) ([]byte, error) {
	secret, err := c.clientSecret(time.Now())
	if err != nil {
		return nil, fmt.Errorf("sign client secret: %w", err)
	}
	form.Set("client_id", c.clientID)
	form.Set("client_secret", secret)

	resp, err := httpClient.PostForm(appleBaseURL+path, form)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		// Apple's error body is a short {"error": "invalid_grant"}, safe and
		// useful to log; it never echoes the secret or the token.
		return nil, fmt.Errorf("apple %s: status %d: %s", path, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return body, nil
}

// exchangeCode trades a one-time authorization code for a refresh token.
func (c *appleClient) exchangeCode(code string) (string, error) {
	body, err := c.post("/auth/token", url.Values{
		"code":       {code},
		"grant_type": {"authorization_code"},
	})
	if err != nil {
		return "", err
	}
	var out struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", fmt.Errorf("parse token response: %w", err)
	}
	if out.RefreshToken == "" {
		return "", errors.New("apple returned no refresh token")
	}
	return out.RefreshToken, nil
}

// revoke invalidates a refresh token, and with it the user's authorisation of
// the app.
func (c *appleClient) revoke(refreshToken string) error {
	_, err := c.post("/auth/revoke", url.Values{
		"token":           {refreshToken},
		"token_type_hint": {"refresh_token"},
	})
	return err
}

// storeAppleRefreshToken exchanges code and keeps the refresh token against
// the user, replacing any earlier one. Best-effort: every failure is logged
// and swallowed, because sign-in has already succeeded by the time this runs.
func storeAppleRefreshToken(app core.App, userID, code string) {
	client, err := loadAppleClient()
	if errors.Is(err, errAppleClientUnconfigured) {
		app.Logger().Debug("apple token exchange skipped: key not configured")
		return
	}
	if err != nil {
		app.Logger().Warn("apple token exchange skipped", "error", err)
		return
	}
	token, err := client.exchangeCode(code)
	if err != nil {
		app.Logger().Warn("apple token exchange failed", "user", userID, "error", err)
		return
	}

	record, _ := app.FindFirstRecordByFilter(appleTokensCollection, "user = {:user}", dbx.Params{"user": userID})
	if record == nil {
		col, err := app.FindCollectionByNameOrId(appleTokensCollection)
		if err != nil {
			app.Logger().Error("apple token not stored", "user", userID, "error", err)
			return
		}
		record = core.NewRecord(col)
		record.Set("user", userID)
	}
	record.Set("refresh_token", token)
	if err := app.Save(record); err != nil {
		app.Logger().Error("apple token not stored", "user", userID, "error", err)
	}
}

// registerAppleRevocation revokes the user's Apple authorisation whenever a
// user record is deleted.
//
// A model hook rather than a call in the account-deletion route, so every way
// of deleting an account revokes — DELETE /api/peard/account, a superuser in
// the dashboard, the opt-in erase on Apple's account-delete notification. The
// refresh token has to be read first: apple_tokens.user cascades, so once the
// delete goes through the row is gone with it.
//
// Revocation happens only after the delete succeeds, so a failed delete
// leaves the account's Apple link working. It is also best-effort, like the
// exchange: a deletion Apple refuses to hear about is still a deletion.
func registerAppleRevocation(app core.App) {
	app.OnRecordDelete("users").BindFunc(func(e *core.RecordEvent) error {
		row, _ := e.App.FindFirstRecordByFilter(appleTokensCollection, "user = {:user}", dbx.Params{"user": e.Record.Id})
		if err := e.Next(); err != nil {
			return err
		}
		if row == nil {
			return nil
		}
		client, err := loadAppleClient()
		if err != nil {
			// A token was stored, so the key was configured once; that it is
			// not now is worth a warning either way.
			e.App.Logger().Warn("apple token not revoked", "user", e.Record.Id, "error", err)
			return nil
		}
		if err := client.revoke(row.GetString("refresh_token")); err != nil {
			e.App.Logger().Warn("apple token not revoked", "user", e.Record.Id, "error", err)
			return nil
		}
		e.App.Logger().Info("apple token revoked", "user", e.Record.Id)
		return nil
	})
}

// deleteAppleTokens drops a user's stored refresh tokens without calling
// Apple, for when Apple has already revoked them (consent-revoked,
// account-delete).
func deleteAppleTokens(app core.App, userID string) error {
	rows, err := app.FindRecordsByFilter(appleTokensCollection, "user = {:user}", "", 0, 0, dbx.Params{"user": userID})
	if err != nil {
		return err
	}
	for _, r := range rows {
		if err := app.Delete(r); err != nil {
			return err
		}
	}
	return nil
}
