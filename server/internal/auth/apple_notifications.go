// Sign in with Apple server-to-server notifications.
//
// Apple POSTs to the endpoint configured on the App ID ("Server-to-Server
// Notification Endpoint") whenever a user changes mail-forwarding preferences,
// revokes the app's access, or deletes their Apple Account. The body is
// {"payload": "<signed JWT>"}, signed with the same keys as the identity token
// and published at the same JWKS URL.
//
// Two things make this token different from an identity token, and both matter:
//
//   - It carries no `exp` claim, so there is nothing to expire. A captured
//     notification would otherwise verify forever and could be replayed to sign
//     a user out at will, so freshness is bounded here with `iat` instead.
//   - The `events` claim is a *string* containing JSON, not a nested object.
//
// Apple retries on any non-2xx response, so a verified notification we choose
// not to act on still answers 200. Only an unverifiable one is rejected.
package auth

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// appleNotificationPath is the absolute path to configure as the App ID's
// Server-to-Server Notification Endpoint, e.g.
// https://peard.kroper.uk/api/peard/auth/apple/notifications
const appleNotificationPath = "/api/peard/auth/apple/notifications"

// Apple's event types.
const (
	eventEmailDisabled  = "email-disabled"
	eventEmailEnabled   = "email-enabled"
	eventConsentRevoked = "consent-revoked"
	eventAccountDelete  = "account-delete"
)

// notificationMaxAge bounds how old a notification may be and still be acted
// on. The token has no `exp`, so without this a replayed capture would be
// valid forever. Apple's retries are far shorter-lived than this window.
const notificationMaxAge = 24 * time.Hour

// notificationClockSkew tolerates a small amount of clock disagreement in the
// other direction, matching the identity token's leeway.
const notificationClockSkew = 5 * time.Minute

type appleNotificationClaims struct {
	Issuer   string          `json:"iss"`
	Audience string          `json:"aud"`
	IssuedAt int64           `json:"iat"`
	JTI      string          `json:"jti"`
	Events   json.RawMessage `json:"events"`
}

type appleNotificationEvent struct {
	Type           string `json:"type"`
	Subject        string `json:"sub"`
	Email          string `json:"email"`
	IsPrivateEmail any    `json:"is_private_email"` // "true"/"false" or true/false
	EventTime      int64  `json:"event_time"`
}

// notificationAction is what a given event type asks us to do.
type notificationAction int

const (
	// actionRecord: nothing to change. The event is logged and acknowledged.
	actionRecord notificationAction = iota
	// actionRevokeAccess: end every session and stop reaching the user —
	// PocketBase auth tokens, widget tokens, APNs devices, and the Apple link.
	// The account and its moments survive.
	actionRevokeAccess
	// actionErase: actionRevokeAccess, then delete the user record outright.
	// Opt-in only; see actionFor.
	actionErase
)

// actionFor maps an event type to what the server does about it.
//
// email-disabled / email-enabled are recorded and no more. Pear'd sends no
// email at all — auth is OAuth-only with unusable passwords, and every
// notification goes over APNs — so mail forwarding being off changes nothing we
// do. The relay address also stays assigned to the app, so it remains valid as
// the linking identity even when it no longer forwards.
//
// consent-revoked means the user withdrew the app's access: the sessions they
// obtained through Apple should stop working.
//
// account-delete means their Apple Account is gone for good. That revokes
// access too, but it does NOT delete the account here by default, because
// posts.author is CascadeDelete (migrations/1785110400_peard_init.go) — so
// deleting the user would erase their moments from the shared timelines of
// every connection they were in, which the other members can see and did not
// ask for. Whether that erasure is right is a product decision about other
// people's data, not something an inbound webhook should settle, so it is
// behind PEARD_APPLE_ERASE_ON_ACCOUNT_DELETE.
func actionFor(eventType string, eraseOnAccountDelete bool) (notificationAction, bool) {
	switch eventType {
	case eventEmailDisabled, eventEmailEnabled:
		return actionRecord, true
	case eventConsentRevoked:
		return actionRevokeAccess, true
	case eventAccountDelete:
		if eraseOnAccountDelete {
			return actionErase, true
		}
		return actionRevokeAccess, true
	}
	return actionRecord, false
}

func eraseOnAccountDelete() bool {
	return strings.EqualFold(strings.TrimSpace(os.Getenv("PEARD_APPLE_ERASE_ON_ACCOUNT_DELETE")), "true")
}

// verifyNotificationToken checks the signature and then the claims that a
// notification token actually has. `now` is a parameter so the freshness window
// is testable.
func verifyNotificationToken(token, expectedAudience string, now time.Time, keyFor keyLookup) (*appleNotificationClaims, error) {
	claimsBytes, err := verifyAppleJWT(token, keyFor)
	if err != nil {
		return nil, err
	}
	var claims appleNotificationClaims
	if err := json.Unmarshal(claimsBytes, &claims); err != nil {
		return nil, fmt.Errorf("parse claims: %w", err)
	}
	if claims.Issuer != appleIssuer {
		return nil, fmt.Errorf("bad issuer %q", claims.Issuer)
	}
	if claims.Audience != expectedAudience {
		return nil, fmt.Errorf("audience %q does not match %q", claims.Audience, expectedAudience)
	}
	if claims.IssuedAt == 0 {
		return nil, errors.New("no iat claim")
	}
	issued := time.Unix(claims.IssuedAt, 0)
	if issued.After(now.Add(notificationClockSkew)) {
		return nil, errors.New("iat is in the future")
	}
	if now.Sub(issued) > notificationMaxAge {
		return nil, fmt.Errorf("notification is %s old, older than the %s replay window",
			now.Sub(issued).Round(time.Second), notificationMaxAge)
	}
	return &claims, nil
}

// parseNotificationEvent reads the `events` claim. Apple documents it as a
// string holding a JSON object, so the common case is a doubly-encoded payload;
// an object is accepted too rather than depending on that staying true.
func parseNotificationEvent(raw json.RawMessage) (*appleNotificationEvent, error) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return nil, errors.New("no events claim")
	}
	if trimmed[0] == '"' {
		var inner string
		if err := json.Unmarshal(trimmed, &inner); err != nil {
			return nil, fmt.Errorf("unwrap events string: %w", err)
		}
		trimmed = bytes.TrimSpace([]byte(inner))
	}
	if len(trimmed) == 0 {
		return nil, errors.New("empty events claim")
	}
	var event appleNotificationEvent
	if err := json.Unmarshal(trimmed, &event); err != nil {
		return nil, fmt.Errorf("parse events: %w", err)
	}
	if event.Type == "" {
		return nil, errors.New("events has no type")
	}
	return &event, nil
}

// appleNotificationKeyLookup resolves the signing key for notification tokens.
// It is a variable solely so the route tests can substitute a locally generated
// key: nothing outside tests reassigns it, and there is no configuration hook to
// point verification at a key Apple does not control.
var appleNotificationKeyLookup keyLookup = applePublicKey

func appleNotificationHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			Payload string `json:"payload" form:"payload"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}
		if body.Payload == "" {
			return e.BadRequestError("payload is required", nil)
		}

		claims, err := verifyNotificationToken(body.Payload, appleAudience(), time.Now(), appleNotificationKeyLookup)
		if err != nil {
			// 401 rather than 200: this did not come from Apple, or not
			// recently enough to trust, and a retry of the same bytes will
			// fail the same way.
			app.Logger().Warn("apple notification rejected", "error", err)
			return e.UnauthorizedError("could not verify notification", err)
		}

		event, err := parseNotificationEvent(claims.Events)
		if err != nil {
			// Verified as Apple's, but not a shape we understand. Acknowledge
			// it — retrying will not make it parse — and record it.
			app.Logger().Error("apple notification unparsable", "jti", claims.JTI, "error", err)
			return e.JSON(http.StatusOK, map[string]any{"status": "unparsable"})
		}

		action, known := actionFor(event.Type, eraseOnAccountDelete())
		user := findUserByAppleSub(app, event.Subject, event.Email)

		app.Logger().Info("apple notification",
			"type", event.Type,
			"known", known,
			"jti", claims.JTI,
			"sub", event.Subject,
			"private_email", claimVerified(event.IsPrivateEmail),
			"matched_user", user != nil,
		)

		if user == nil || action == actionRecord {
			// Nothing to do: either we never saw this Apple user (they signed
			// in, we linked by email, and the account has since gone), or the
			// event carries no action for us.
			return e.JSON(http.StatusOK, map[string]any{"status": "acknowledged"})
		}

		if err := applyNotificationAction(app, user, action); err != nil {
			// A 500 asks Apple to retry, which is what we want: the account is
			// still live and the revocation has not happened.
			app.Logger().Error("apple notification action failed",
				"type", event.Type, "user", user.Id, "error", err)
			return e.InternalServerError("failed to apply notification", err)
		}
		return e.JSON(http.StatusOK, map[string]any{"status": "applied"})
	}
}

// findUserByAppleSub resolves the account an event refers to.
//
// The Apple `sub` recorded at sign-in is the reliable key; the email is a
// fallback because a private relay address can be the only thing an
// email-disabled event has in common with the record, and because the
// _externalAuths link is written best-effort at sign-in.
func findUserByAppleSub(app core.App, sub, email string) *core.Record {
	if sub != "" {
		link, err := app.FindFirstRecordByFilter(core.CollectionNameExternalAuths,
			"provider = 'apple' && providerId = {:sub}", dbx.Params{"sub": sub})
		if err == nil && link != nil {
			if user, err := app.FindRecordById("users", link.GetString("recordRef")); err == nil && user != nil {
				return user
			}
		}
	}
	if email != "" {
		user, err := app.FindFirstRecordByFilter("users", "email = {:email}",
			dbx.Params{"email": strings.ToLower(strings.TrimSpace(email))})
		if err == nil && user != nil {
			return user
		}
	}
	return nil
}

// applyNotificationAction performs the revocation (and optionally the erasure)
// in one transaction, so a partial revocation cannot be left behind — a user
// whose devices were removed but whose auth token still works would keep
// posting with no way to reach them.
func applyNotificationAction(app core.App, user *core.Record, action notificationAction) error {
	return app.RunInTransaction(func(txApp core.App) error {
		txUser, err := txApp.FindRecordById("users", user.Id)
		if err != nil {
			return err
		}

		// Stop pushing to their devices.
		devices, err := txApp.FindRecordsByFilter("devices",
			"user = {:user}", "", 0, 0, dbx.Params{"user": txUser.Id})
		if err != nil {
			return err
		}
		for _, d := range devices {
			if err := txApp.Delete(d); err != nil {
				return err
			}
		}

		// Revoke widget tokens. These live in the App Group container, outside
		// the Keychain, so they outlive a session and have to be killed
		// explicitly. Filtered in Go rather than SQL so the result does not
		// depend on how an unset boolean compares.
		tokens, err := txApp.FindRecordsByFilter("widget_tokens",
			"user = {:user}", "", 0, 0, dbx.Params{"user": txUser.Id})
		if err != nil {
			return err
		}
		for _, t := range tokens {
			if t.GetBool("revoked") {
				continue
			}
			t.Set("revoked", true)
			if err := txApp.Save(t); err != nil {
				return err
			}
		}

		// Drop the Apple link. If they later sign in with Apple again — only
		// possible for consent-revoked, not for a deleted Apple Account — it is
		// rewritten then.
		links, err := txApp.FindRecordsByFilter(core.CollectionNameExternalAuths,
			"recordRef = {:id} && provider = 'apple'", "", 0, 0, dbx.Params{"id": txUser.Id})
		if err != nil {
			return err
		}
		for _, l := range links {
			if err := txApp.Delete(l); err != nil {
				return err
			}
		}

		if action == actionErase {
			// Cascades: pair_members, posts (and their reactions), reactions,
			// invites, devices, widget_tokens.
			return txApp.Delete(txUser)
		}

		// Invalidate every issued PocketBase auth token for this user.
		txUser.RefreshTokenKey()
		return txApp.Save(txUser)
	})
}
