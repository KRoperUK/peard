// Package auth implements Pear'd custom auth routes.
//
// POST /api/peard/auth/apple verifies a native Sign in with Apple identity
// token (RS256 JWT) against Apple's JWKS endpoint, finds or creates the user
// by verified email — email is the linking identity across providers — and
// returns a PocketBase auth token + user record.
//
// Google sign-in is handled by PocketBase's built-in OAuth2 code exchange
// (pb.collection('users').authWithOAuth2Code), which links to the same user
// record by verified email.
package auth

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

const (
	appleIssuer  = "https://appleid.apple.com"
	appleJWKSURL = appleIssuer + "/auth/keys"
)

// Register binds the custom auth routes.
func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.POST("/api/peard/auth/apple", appleSignInHandler(app))
		return se.Next()
	})
}

func appleSignInHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			IdentityToken string `json:"identity_token" form:"identity_token"`
			Nonce         string `json:"nonce" form:"nonce"`
			DisplayName   string `json:"display_name" form:"display_name"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}
		if body.IdentityToken == "" {
			return e.BadRequestError("identity_token is required", nil)
		}

		audience := os.Getenv("PEARD_APPLE_AUDIENCE")
		if audience == "" {
			audience = "com.peard.app"
		}

		claims, err := verifyIdentityToken(body.IdentityToken, audience, body.Nonce)
		if err != nil {
			return e.UnauthorizedError("invalid identity token", err)
		}
		if claims.Email == "" {
			// Apple only includes the email on the FIRST authorization.
			return e.BadRequestError("identity token has no email claim; revoke the app's access under Settings > Apple Account > Sign in with Apple and sign in again", nil)
		}
		if !claimVerified(claims.EmailVerified) {
			return e.BadRequestError("apple reports this email as unverified", nil)
		}
		email := strings.ToLower(strings.TrimSpace(claims.Email))

		user, err := app.FindFirstRecordByFilter("users", "email = {:email}", dbx.Params{"email": email})
		if err != nil || user == nil {
			// First time we have seen this email: create the account.
			usersCol, err := app.FindCollectionByNameOrId("users")
			if err != nil {
				return e.InternalServerError("users collection missing", err)
			}
			user = core.NewRecord(usersCol)
			user.SetEmail(email)
			user.SetVerified(true)
			user.Set("display_name", body.DisplayName)
			user.SetPassword(randHex(24)) // unusable password; account is OAuth-only
			if err := app.Save(user); err != nil {
				return e.InternalServerError("failed to create user", err)
			}
		} else if body.DisplayName != "" && user.GetString("display_name") == "" {
			// Apple sends the name only once; persist it if we don't have one.
			user.Set("display_name", body.DisplayName)
			_ = app.Save(user) // non-fatal
		}

		linkAppleExternalAuth(app, user, claims.Subject)

		token, err := user.NewAuthToken()
		if err != nil {
			return e.InternalServerError("failed to mint auth token", err)
		}
		return e.JSON(http.StatusOK, map[string]any{
			"token":  token,
			"record": user,
		})
	}
}

// linkAppleExternalAuth records the Apple user id (sub) in PocketBase's
// _externalAuths collection so PB-native flows recognise the link too.
// Best-effort: failures are ignored.
func linkAppleExternalAuth(app core.App, user *core.Record, appleSub string) {
	col, err := app.FindCollectionByNameOrId(core.CollectionNameExternalAuths)
	if err != nil {
		return
	}
	existing, _ := app.FindFirstRecordByFilter(col.Name,
		"recordRef = {:id} && provider = 'apple'", dbx.Params{"id": user.Id})
	if existing != nil {
		return
	}
	rec := core.NewRecord(col)
	rec.Set("collectionRef", user.Collection().Id)
	rec.Set("recordRef", user.Id)
	rec.Set("provider", "apple")
	rec.Set("providerId", appleSub)
	_ = app.Save(rec)
}

// ---------------------------------------------------------------------------
// Apple identity token (JWT) verification — stdlib only, no extra deps.
// ---------------------------------------------------------------------------

type appleClaims struct {
	Issuer        string `json:"iss"`
	Subject       string `json:"sub"`
	Audience      string `json:"aud"`
	ExpiresAt     int64  `json:"exp"`
	IssuedAt      int64  `json:"iat"`
	Email         string `json:"email"`
	EmailVerified any    `json:"email_verified"` // Apple sends "true" or true
	Nonce         string `json:"nonce"`
}

func verifyIdentityToken(token, expectedAudience, rawNonce string) (*appleClaims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, errors.New("malformed JWT")
	}

	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, fmt.Errorf("decode header: %w", err)
	}
	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return nil, fmt.Errorf("parse header: %w", err)
	}
	if header.Alg != "RS256" {
		return nil, fmt.Errorf("unexpected alg %q", header.Alg)
	}

	key, err := applePublicKey(header.Kid)
	if err != nil {
		return nil, err
	}

	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, fmt.Errorf("decode signature: %w", err)
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], sig); err != nil {
		return nil, fmt.Errorf("signature: %w", err)
	}

	claimsBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("decode claims: %w", err)
	}
	var claims appleClaims
	if err := json.Unmarshal(claimsBytes, &claims); err != nil {
		return nil, fmt.Errorf("parse claims: %w", err)
	}

	if claims.Issuer != appleIssuer {
		return nil, fmt.Errorf("bad issuer %q", claims.Issuer)
	}
	if claims.Audience != expectedAudience {
		return nil, fmt.Errorf("audience %q does not match %q", claims.Audience, expectedAudience)
	}
	if time.Now().Unix() > claims.ExpiresAt+300 { // 5 min clock-skew leeway
		return nil, errors.New("token expired")
	}
	// The client sets the ASAuthorizationRequest nonce to SHA-256(rawNonce);
	// Apple echoes it back as the `nonce` claim. Some client libs pass the raw
	// value straight through instead, so accept either form.
	if rawNonce != "" && claims.Nonce != "" {
		sum := sha256.Sum256([]byte(rawNonce))
		if !strings.EqualFold(claims.Nonce, hex.EncodeToString(sum[:])) && claims.Nonce != rawNonce {
			return nil, errors.New("nonce mismatch")
		}
	}
	return &claims, nil
}

func claimVerified(v any) bool {
	switch t := v.(type) {
	case bool:
		return t
	case string:
		return t == "true"
	}
	return false
}

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// --- Apple JWKS fetching/caching -------------------------------------------

type jwksKey struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	Use string `json:"use"`
	Alg string `json:"alg"`
	N   string `json:"n"`
	E   string `json:"e"`
}

var (
	keysMu     sync.RWMutex
	keysCache  []jwksKey
	keysCached time.Time
	httpClient = &http.Client{Timeout: 10 * time.Second}
)

func applePublicKey(kid string) (*rsa.PublicKey, error) {
	keys, err := appleKeys()
	if err != nil {
		return nil, err
	}
	for _, k := range keys {
		if k.Kid != kid || k.Kty != "RSA" {
			continue
		}
		nBytes, err := base64.RawURLEncoding.DecodeString(k.N)
		if err != nil {
			return nil, fmt.Errorf("decode modulus: %w", err)
		}
		eBytes, err := base64.RawURLEncoding.DecodeString(k.E)
		if err != nil {
			return nil, fmt.Errorf("decode exponent: %w", err)
		}
		e := 0
		for _, b := range eBytes {
			e = e<<8 | int(b)
		}
		return &rsa.PublicKey{N: new(big.Int).SetBytes(nBytes), E: e}, nil
	}
	return nil, errors.New("no matching Apple key for kid " + kid)
}

func appleKeys() ([]jwksKey, error) {
	keysMu.RLock()
	if len(keysCache) > 0 && time.Since(keysCached) < 24*time.Hour {
		defer keysMu.RUnlock()
		return keysCache, nil
	}
	keysMu.RUnlock()

	resp, err := httpClient.Get(appleJWKSURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	var doc struct {
		Keys []jwksKey `json:"keys"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, err
	}
	if len(doc.Keys) == 0 {
		return nil, errors.New("apple JWKS document is empty")
	}

	keysMu.Lock()
	keysCache = doc.Keys
	keysCached = time.Now()
	keysMu.Unlock()
	return doc.Keys, nil
}
