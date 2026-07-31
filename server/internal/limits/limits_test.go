package limits

import (
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

func newApp(t *testing.T) *tests.TestApp {
	t.Helper()
	app, err := tests.NewTestApp(t.TempDir())
	if err != nil {
		t.Fatalf("new test app: %v", err)
	}
	t.Cleanup(app.Cleanup)
	return app
}

func TestApplyTurnsRateLimitingOn(t *testing.T) {
	app := newApp(t)
	app.Settings().RateLimits.Enabled = false

	apply(app)

	if !app.Settings().RateLimits.Enabled {
		t.Fatal("rate limiting is still off")
	}
	if len(app.Settings().RateLimits.Rules) == 0 {
		t.Fatal("no rules were set")
	}
}

// The escape hatch is the reason it was safe to switch these on at all, so it
// gets a test rather than a comment.
func TestPEARDRateLimitsOffDisablesEverything(t *testing.T) {
	for _, value := range []string{"off", "OFF", "false", "0", "no", " off "} {
		t.Run(value, func(t *testing.T) {
			t.Setenv("PEARD_RATE_LIMITS", value)
			app := newApp(t)
			app.Settings().RateLimits.Enabled = true

			apply(app)

			if app.Settings().RateLimits.Enabled {
				t.Fatalf("PEARD_RATE_LIMITS=%q left rate limiting on", value)
			}
		})
	}
}

func TestAnUnrelatedValueLeavesLimitsOn(t *testing.T) {
	t.Setenv("PEARD_RATE_LIMITS", "on")
	app := newApp(t)

	apply(app)

	if !app.Settings().RateLimits.Enabled {
		t.Fatal("only an explicit off value should disable limits")
	}
}

// Every rule has to satisfy PocketBase's own validation, or the settings fail to
// save at boot and the server comes up with no limits at all — the opposite of
// the intent, and silent.
func TestEveryRuleIsValid(t *testing.T) {
	for _, rule := range rules() {
		if err := rule.Validate(); err != nil {
			t.Errorf("rule %q is invalid: %v", rule.Label, err)
		}
	}
}

// A limit that fires during ordinary use is worse than no limit, because a
// request rejected for no visible reason looks like a broken server. These
// assert the headroom rather than the exact numbers.
func TestLimitsLeaveRoomForNormalUse(t *testing.T) {
	byLabel := map[string]core.RateLimitRule{}
	for _, rule := range rules() {
		byLabel[rule.Label] = rule
	}

	cases := []struct {
		label   string
		atLeast float64
		because string
	}{
		{"/api/peard/widget/", 60, "several widgets refresh independently and again after every button tap"},
		{"/api/peard/contacts/match", 5, "opening Find Friends more than once in a session must not fail"},
		{"/api/", 600, "the catch-all must never be the thing that stops ordinary browsing"},
	}

	for _, c := range cases {
		rule, ok := byLabel[c.label]
		if !ok {
			t.Errorf("no rule for %q", c.label)
			continue
		}
		perMinute := float64(rule.MaxRequests) * (60.0 / float64(rule.Duration))
		if perMinute < c.atLeast {
			t.Errorf("%q allows %.0f/min, want at least %.0f — %s",
				c.label, perMinute, c.atLeast, c.because)
		}
	}
}

// Sign-up is the only public write, so its limit is the one that actually
// matters for abuse. Tight, but not so tight that a person who mistypes their
// email twice is locked out.
func TestSignUpIsLimitedButNotHostile(t *testing.T) {
	var rule core.RateLimitRule
	for _, r := range rules() {
		if r.Label == "users:create" {
			rule = r
		}
	}
	if rule.Label == "" {
		t.Fatal("no users:create rule — account creation is unlimited")
	}
	if rule.Audience != core.RateLimitRuleAudienceGuest {
		t.Errorf("audience is %q, want @guest so it cannot affect signed-in users", rule.Audience)
	}
	if rule.MaxRequests < 3 {
		t.Errorf("only %d attempts per %ds — a couple of typos would lock somebody out",
			rule.MaxRequests, rule.Duration)
	}
	if rule.MaxRequests > 20 {
		t.Errorf("%d attempts per %ds is not much of a limit", rule.MaxRequests, rule.Duration)
	}
}

// The client IP is what every rule keys on, so these matter as much as the
// numbers do. Getting them wrong does not fail — it silently makes each rule
// apply to everybody at once.

func TestNoTrustedHeaderByDefault(t *testing.T) {
	app := newApp(t)

	apply(app)

	if got := app.Settings().TrustedProxy.Headers; len(got) != 0 {
		t.Fatalf("trusts %v by default — a header nobody checks is one anybody can forge", got)
	}
}

func TestTrustedHeaderIsReadFromTheEnvironment(t *testing.T) {
	t.Setenv("PEARD_TRUSTED_PROXY_HEADER", "CF-Connecting-IP")
	app := newApp(t)

	apply(app)

	headers := app.Settings().TrustedProxy.Headers
	if len(headers) != 1 || headers[0] != "CF-Connecting-IP" {
		t.Fatalf("got %v, want [CF-Connecting-IP]", headers)
	}
}

func TestSeveralTrustedHeadersAreSplitAndTrimmed(t *testing.T) {
	t.Setenv("PEARD_TRUSTED_PROXY_HEADER", " CF-Connecting-IP , X-Forwarded-For ")
	app := newApp(t)

	apply(app)

	headers := app.Settings().TrustedProxy.Headers
	if len(headers) != 2 || headers[0] != "CF-Connecting-IP" || headers[1] != "X-Forwarded-For" {
		t.Fatalf("got %v, want both headers trimmed", headers)
	}
}

// The rightmost entry is the one the nearest proxy wrote; the leftmost is
// whatever the client sent, which is the forgeable one.
func TestLeftmostIPIsNotUsed(t *testing.T) {
	t.Setenv("PEARD_TRUSTED_PROXY_HEADER", "X-Forwarded-For")
	app := newApp(t)

	apply(app)

	if app.Settings().TrustedProxy.UseLeftmostIP {
		t.Fatal("leftmost IP is client-controlled and would let anybody pick their own rate limit bucket")
	}
}

// Turning the limits off must not also turn off the IP resolution — anything
// else that keys on the client address should keep working.
func TestTrustedHeaderSurvivesLimitsBeingDisabled(t *testing.T) {
	t.Setenv("PEARD_RATE_LIMITS", "off")
	t.Setenv("PEARD_TRUSTED_PROXY_HEADER", "CF-Connecting-IP")
	app := newApp(t)

	apply(app)

	if app.Settings().RateLimits.Enabled {
		t.Fatal("limits should be off")
	}
	if len(app.Settings().TrustedProxy.Headers) != 1 {
		t.Fatal("trusted proxy config was dropped along with the limits")
	}
}
