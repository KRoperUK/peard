// Package limits turns on PocketBase's request rate limiting and sets the rules
// Pear'd wants on top of the stock ones.
//
// PocketBase ships sensible defaults but leaves them switched off, so this
// server had no rate limiting of any kind. That mattered less when every write
// needed an account somebody had been invited into; it matters now that the app
// creates accounts, because `POST /api/collections/users/records` is a public
// endpoint that writes a row.
//
// The rules below are deliberately loose. The goal is to stop a script, not to
// interrupt anybody: every limit here is well above what the app produces in
// normal use, including a widget refreshing on several home screens at once and
// somebody tapping moments quickly. A rate limit that fires on real use is worse
// than none, because the failure — a request rejected for no reason the user can
// see — is indistinguishable from the server being broken.
//
// Set PEARD_RATE_LIMITS=off to disable the lot without a redeploy. That exists
// because a limit that misfires in production needs a way out that does not
// involve editing code, and because these were switched on without a load test
// to size them against.
package limits

import (
	"os"
	"strings"

	"github.com/pocketbase/pocketbase/core"
)

// Register applies the rules on bootstrap.
//
// Settings live in the database, so this rewrites them on every start — the same
// approach `main.go` already takes for the app name and URL. The consequence
// worth knowing is that editing these in the PB dashboard will not stick; the
// code is the source of truth, and the env var is the override.
func Register(app core.App) {
	app.OnBootstrap().BindFunc(func(e *core.BootstrapEvent) error {
		if err := e.Next(); err != nil {
			return err
		}
		apply(e.App)
		return nil
	})
}

func apply(app core.App) {
	settings := app.Settings()

	if disabled() {
		settings.RateLimits.Enabled = false
		return
	}

	settings.RateLimits.Enabled = true
	settings.RateLimits.Rules = rules()
}

func disabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("PEARD_RATE_LIMITS"))) {
	case "off", "false", "0", "no":
		return true
	default:
		return false
	}
}

// rules is the whole policy, most specific first — PocketBase prefers an exact
// label over a prefix, so the ordering here is for readers rather than for
// matching.
func rules() []core.RateLimitRule {
	return []core.RateLimitRule{
		// Sign-in. Two attempts every three seconds is PocketBase's own default
		// and is plenty for a person typing a password; it makes credential
		// stuffing pointlessly slow.
		{Label: "*:auth", MaxRequests: 2, Duration: 3},

		// Account creation, guests only. The route the app's new sign-up button
		// posts to, and the only public write on the server. Five a minute is
		// far more than one person needs and far less than a script wants.
		// Scoped to @guest so it can never affect somebody already signed in.
		{Label: "users:create", Audience: core.RateLimitRuleAudienceGuest, MaxRequests: 5, Duration: 60},

		// Native Sign in with Apple. Same shape as *:auth, but it is a custom
		// route rather than a collection action, so the tag does not cover it.
		{Label: "/api/peard/auth/apple", MaxRequests: 5, Duration: 10},

		// Contact matching hashes and compares up to a few hundred entries per
		// call. Nobody's address book changes twice a minute, and the app only
		// sends this when the Find Friends screen is opened.
		{Label: "/api/peard/contacts/match", MaxRequests: 6, Duration: 60},

		// A full export of one account. Expensive, and wanted about once ever.
		{Label: "/api/peard/export", MaxRequests: 3, Duration: 60},

		// Widget and Messages traffic, which is token-authenticated rather than
		// session-authenticated and so counts as a guest. Generous on purpose:
		// several widgets on several home screens each refresh on their own
		// schedule and again after every button tap, and a widget that starts
		// failing is one somebody has to notice and reinstall.
		{Label: "/api/peard/widget/", MaxRequests: 120, Duration: 60},

		// Everything else, matching PocketBase's stock catch-alls.
		{Label: "*:create", MaxRequests: 20, Duration: 5},
		{Label: "/api/batch", MaxRequests: 3, Duration: 1},
		{Label: "/api/", MaxRequests: 300, Duration: 10},
	}
}
