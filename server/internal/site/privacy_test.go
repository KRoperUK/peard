package site_test

import (
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

// The app's consent gate stores the policy version it accepted, and asks again
// when PrivacyConsent.currentVersion moves. That only works if the version moves
// whenever this page's date does, so the two are checked against each other
// here: bumping one without the other fails the build rather than silently
// skipping the re-consent the policy promises.
func TestPrivacyPolicyDateMatchesTheAppsConsentVersion(t *testing.T) {
	source, err := os.ReadFile("../../../ios/PeardCore/Sources/PeardCore/PrivacyConsent.swift")
	if err != nil {
		t.Fatalf("read PrivacyConsent.swift: %v", err)
	}
	match := regexp.MustCompile(`currentVersion = "(\d{4}-\d{2}-\d{2})"`).FindSubmatch(source)
	if match == nil {
		t.Fatal("no currentVersion in PrivacyConsent.swift")
	}
	version, err := time.Parse("2006-01-02", string(match[1]))
	if err != nil {
		t.Fatalf("currentVersion %q is not a date: %v", match[1], err)
	}

	body := get(t, newSiteMux(t), "/privacy").Body.String()
	want := "Last updated " + version.Format("2 January 2006")
	if !strings.Contains(body, want) {
		t.Errorf("/privacy does not say %q, so it and the app's consent version (%s) have drifted", want, match[1])
	}
}

// Things the policy has to disclose because the service does them. Each needle
// stands for a whole paragraph; this catches one being dropped, not bad prose.
func TestPrivacyPolicyDisclosesWhatIsCollected(t *testing.T) {
	body := get(t, newSiteMux(t), "/privacy").Body.String()

	for what, needle := range map[string]string{
		"request logs keep IP addresses": "IP address",
		"and for how long":               "deleted automatically after 5 days",
		"widget tokens":                  "Widget tokens",
		"Live Activity tokens":           "Live Activity",
		"beta feedback to OpenRouter":    "OpenRouter",
		"beta feedback to GitHub":        "GitHub repository, which is public",
		"tester identity not published":  "never names you",
		"the complete export":            "everything we hold about you",
		"export photo links expire":      "30 minutes",
		"Apple revocation on deletion":   "revoke Pear'd's access",
		"device time zones":              "Time zone",
	} {
		if !strings.Contains(body, needle) {
			t.Errorf("/privacy no longer covers %s (%q)", what, needle)
		}
	}
}

// The consent section says the app asks again after a change; "Changes" used
// to say only the date moves. Both have to tell the same story.
func TestPrivacyPolicyChangesSectionPromisesReconsent(t *testing.T) {
	body := get(t, newSiteMux(t), "/privacy").Body.String()

	start := strings.Index(body, "<h2>Changes</h2>")
	if start < 0 {
		t.Fatal("/privacy has no Changes section")
	}
	section := body[start:]
	if end := strings.Index(section[len("<h2>Changes</h2>"):], "<h2>"); end >= 0 {
		section = section[:end+len("<h2>Changes</h2>")]
	}
	if !strings.Contains(section, "asks you to agree to the new version") {
		t.Errorf("the Changes section does not mention the app asking again: %s", section)
	}
}
