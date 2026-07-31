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
//
// # Who a limit applies to
//
// Every rule is keyed on the client IP, which PocketBase resolves from the
// direct connection unless it has been told which proxy header to trust. That
// default is the safe one — a header nobody checks is a header anybody can forge
// — but it is wrong the moment the server sits behind a proxy, because then
// every request arrives from the same address.
//
// This deployment runs behind a cloudflared tunnel (docker-compose.cloudflared.yml
// publishes no host port at all), so without PEARD_TRUSTED_PROXY_HEADER the
// entire user base would share one bucket: two sign-ins every three seconds for
// everybody at once, not per person. Which is worse than having no rate limiting,
// and would have looked exactly like the server falling over.
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

	// Before the rules, and regardless of whether they are on: the client IP is
	// what the limiter keys on, so an unset one makes every rule below mean
	// something other than what it says.
	headers := trustedProxyHeaders()
	settings.TrustedProxy.Headers = headers
	settings.TrustedProxy.UseLeftmostIP = false

	if disabled() {
		settings.RateLimits.Enabled = false
		app.Logger().Warn("rate limiting disabled by PEARD_RATE_LIMITS")
		return
	}

	settings.RateLimits.Enabled = true
	settings.RateLimits.Rules = rules()

	// Said out loud at boot because getting this wrong is otherwise invisible:
	// the server behaves normally until enough people use it at once, and then
	// rate-limits them collectively. A log line is the difference between
	// "check the startup output" and "work out why sign-in fails for everybody
	// at 9am".
	if len(headers) == 0 {
		app.Logger().Info(
			"rate limiting enabled, keyed on the direct connection IP; " +
				"set PEARD_TRUSTED_PROXY_HEADER if this server is behind a proxy, " +
				"or every client will share one limit",
		)
	} else {
		app.Logger().Info("rate limiting enabled", "clientIPFrom", strings.Join(headers, ", "))
	}
}

// trustedProxyHeaders reads PEARD_TRUSTED_PROXY_HEADER, a comma-separated list.
//
// Empty by default, and that default is deliberate: trusting a header on a
// server that is reachable directly lets any client claim any IP, which turns
// every rate limit into a formality. It is only correct to set this when
// something in front of the server is guaranteed to overwrite the header, and
// when the server cannot be reached around that thing.
//
// Both conditions hold for the cloudflared deployment — Cloudflare sets
// CF-Connecting-IP itself, and the container publishes no host port — so the
// compose override sets it there rather than defaulting it on here, where it
// would also apply to deployments that publish a port.
//
// UseLeftmostIP stays false. CF-Connecting-IP carries exactly one address, and
// for the X-Forwarded-For style the rightmost entry is the one the nearest proxy
// wrote; the leftmost is whatever the client sent, which is the forgeable one.
func trustedProxyHeaders() []string {
	raw := strings.TrimSpace(os.Getenv("PEARD_TRUSTED_PROXY_HEADER"))
	if raw == "" {
		return nil
	}
	var headers []string
	for _, part := range strings.Split(raw, ",") {
		if name := strings.TrimSpace(part); name != "" {
			headers = append(headers, name)
		}
	}
	return headers
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
