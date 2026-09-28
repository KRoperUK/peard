package site_test

import (
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
	"github.com/pocketbase/pocketbase/ui"

	"peard/internal/site"
)

func newSiteMux(t *testing.T) http.Handler {
	t.Helper()

	dir, err := os.MkdirTemp("", "peard-site-test-*")
	if err != nil {
		t.Fatalf("temp dir: %v", err)
	}
	app, err := tests.NewTestApp(dir)
	if err != nil {
		os.RemoveAll(dir)
		t.Fatalf("new test app: %v", err)
	}
	t.Cleanup(func() {
		app.Cleanup()
		os.RemoveAll(dir)
	})

	site.Register(app)

	router, err := apis.NewRouter(app)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}
	// The superuser UI is registered by apis.Serve rather than NewRouter, so it
	// is added here the same way, to prove the site's catch-all leaves it alone.
	router.GET("/_/{path...}", apis.Static(ui.DistDirFS, false))
	event := new(core.ServeEvent)
	event.App = app
	event.Router = router

	var mux http.Handler
	if err := app.OnServe().Trigger(event, func(e *core.ServeEvent) error {
		built, err := e.Router.BuildMux()
		if err != nil {
			return err
		}
		mux = built
		return nil
	}); err != nil {
		t.Fatalf("build mux: %v", err)
	}
	return mux
}

func get(t *testing.T, mux http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
	return rec
}

// The association file is what iOS fetches to decide whether this domain may
// open the app. A wrong value here fails silently — universal links simply
// stop working — so it is worth asserting rather than eyeballing.
func TestSiteAssociationClaimsOnlyTheInvitePath(t *testing.T) {
	mux := newSiteMux(t)

	rec := get(t, mux, "/.well-known/apple-app-site-association")

	if rec.Code != http.StatusOK {
		t.Fatalf("got %d, want 200", rec.Code)
	}
	// Apple requires application/json, and the file must have no extension.
	if got := rec.Header().Get("Content-Type"); !strings.HasPrefix(got, "application/json") {
		t.Fatalf("content type %q, want application/json", got)
	}

	var parsed struct {
		Applinks struct {
			Details []struct {
				AppIDs     []string `json:"appIDs"`
				Components []struct {
					Path string `json:"/"`
				} `json:"components"`
			} `json:"details"`
		} `json:"applinks"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &parsed); err != nil {
		t.Fatalf("decode: %v (body %s)", err, rec.Body.String())
	}
	if len(parsed.Applinks.Details) != 1 {
		t.Fatalf("got %d details, want 1", len(parsed.Applinks.Details))
	}
	detail := parsed.Applinks.Details[0]
	if len(detail.AppIDs) != 1 || detail.AppIDs[0] != "72Q6R744M4.com.peard.app" {
		t.Fatalf("app ids %v", detail.AppIDs)
	}
	// Only /c/*. Claiming the whole domain would take /privacy with it, and a
	// privacy policy that opens the app rather than a page is unreadable to an
	// app-store reviewer.
	if len(detail.Components) != 1 || detail.Components[0].Path != "/c/*" {
		t.Fatalf("components %v, want only /c/*", detail.Components)
	}
}

func TestInvitePageShowsTheCodeAndTheTestFlightStep(t *testing.T) {
	mux := newSiteMux(t)

	rec := get(t, mux, "/c/AB12CD")

	if rec.Code != http.StatusOK {
		t.Fatalf("got %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	// The code has to be on the page: the TestFlight round trip loses the
	// link, and typing it in afterwards is the only way back.
	if !strings.Contains(body, "AB12CD") {
		t.Fatal("expected the invite code on the page")
	}
	if !strings.Contains(body, "testflight.apple.com") {
		t.Fatal("expected a TestFlight link")
	}
}

// A lower-case link still resolves — the code is normalised the same way the
// app normalises it.
func TestInvitePageUpperCasesTheCode(t *testing.T) {
	mux := newSiteMux(t)

	body := get(t, mux, "/c/ab12cd").Body.String()

	if !strings.Contains(body, "AB12CD") {
		t.Fatal("expected the code upper-cased")
	}
}

// Anything that is not a plausible code is somebody poking at the URL, and the
// page must not be rendered for it.
func TestInvitePageRefusesSomethingThatIsNotACode(t *testing.T) {
	mux := newSiteMux(t)

	for _, path := range []string{
		"/c/toolongtobeacodeatall",
		"/c/AB-12",
		"/c/ab_12",
	} {
		rec := get(t, mux, path)
		if rec.Code != http.StatusNotFound {
			t.Fatalf("%s: got %d, want 404", path, rec.Code)
		}
	}
}

// Nothing from the URL reaches the HTML. The code is interpolated into the page
// unescaped — which is safe only because the pattern above admits nothing but
// A-Z and 0-9, so this asserts the property that makes it safe rather than
// trusting it.
func TestInvitePageNeverReflectsItsInput(t *testing.T) {
	mux := newSiteMux(t)

	for _, path := range []string{
		"/c/%3Cscript%3Ealert(1)%3C/script%3E",
		"/c/%22onerror%3Dalert(1)",
		"/c/AB12CD%3Cimg%3E",
	} {
		body := get(t, mux, path).Body.String()
		for _, forbidden := range []string{"<script", "onerror", "<img"} {
			if strings.Contains(strings.ToLower(body), forbidden) {
				t.Fatalf("%s: reflected %q into the page", path, forbidden)
			}
		}
	}
}

// The pages that were already there keep working, and keep being pages.
func TestTheMarketingPagesStillServe(t *testing.T) {
	mux := newSiteMux(t)

	for _, path := range []string{"/", "/privacy", "/support"} {
		if code := get(t, mux, path).Code; code != http.StatusOK {
			t.Fatalf("%s: got %d, want 200", path, code)
		}
	}
}

// Every page, invite pages included, points at the source. The footer is shared,
// so this is really checking nothing renders a page without it.
func TestEveryPageLinksTheSource(t *testing.T) {
	mux := newSiteMux(t)

	for _, path := range []string{"/", "/privacy", "/c/ABC123"} {
		body := get(t, mux, path).Body.String()
		if !strings.Contains(body, `href="https://github.com/KRoperUK/peard"`) {
			t.Errorf("%s: no link to the repo in the footer", path)
		}
	}
}

// An unknown path is a 404 with a page that leads home, not the home page with
// a 200 — which search engines treat as a soft 404.
func TestUnknownPathsAreANotFoundPage(t *testing.T) {
	mux := newSiteMux(t)

	for _, path := range []string{"/nope", "/privacy.html", "/c", "/privacy/extra"} {
		rec := get(t, mux, path)
		if rec.Code != http.StatusNotFound {
			t.Fatalf("%s: got %d, want 404", path, rec.Code)
		}
		body := rec.Body.String()
		if !strings.Contains(body, "Nothing here") || !strings.Contains(body, `class="cta" href="/"`) {
			t.Fatalf("%s: expected the not-found page with a link home", path)
		}
		if strings.Contains(body, "Try it on TestFlight") {
			t.Fatalf("%s: served the home page", path)
		}
	}
}

// The routes that should answer still do, including the ones that sit beside the
// catch-all: invite links and the association file.
func TestKnownPathsAreNotCaughtByTheNotFoundPage(t *testing.T) {
	mux := newSiteMux(t)

	for _, path := range []string{"/", "/privacy", "/support", "/c/AB12CD", "/.well-known/apple-app-site-association"} {
		rec := get(t, mux, path)
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: got %d, want 200", path, rec.Code)
		}
		if strings.Contains(rec.Body.String(), "Nothing here") {
			t.Fatalf("%s: served the not-found page", path)
		}
	}
}

// PocketBase's own routes sit on the same mux. They must still win over the
// site's catch-all, and an unknown API path must keep PocketBase's JSON error
// rather than an HTML page an API client can't read.
func TestPocketBaseRoutesAreUnaffected(t *testing.T) {
	mux := newSiteMux(t)

	health := get(t, mux, "/api/health")
	if health.Code != http.StatusOK || !strings.HasPrefix(health.Header().Get("Content-Type"), "application/json") {
		t.Fatalf("/api/health: got %d %q, want 200 JSON", health.Code, health.Header().Get("Content-Type"))
	}

	missing := get(t, mux, "/api/nope")
	if missing.Code != http.StatusNotFound || !strings.HasPrefix(missing.Header().Get("Content-Type"), "application/json") {
		t.Fatalf("/api/nope: got %d %q, want 404 JSON", missing.Code, missing.Header().Get("Content-Type"))
	}

	admin := get(t, mux, "/_/")
	if admin.Code != http.StatusOK || strings.Contains(admin.Body.String(), "Nothing here") {
		t.Fatalf("/_/: got %d, want the superuser UI", admin.Code)
	}
}

// Every text colour clears WCAG AA (4.5:1) against every background it is set
// on, in both colour schemes. The accent is the one that slipped before — as a
// link colour and as the button fill — so a palette tweak that loses it again
// should fail here rather than in somebody's eyes.
func TestColoursMeetWCAGContrast(t *testing.T) {
	body := get(t, newSiteMux(t), "/").Body.String()

	// The light palette is the first :root block; the dark one is the :root
	// inside the prefers-color-scheme media query.
	darkAt := strings.Index(body, "@media (prefers-color-scheme: dark)")
	if darkAt < 0 {
		t.Fatal("no dark-mode palette in the page")
	}
	schemes := map[string]map[string]string{
		"light": cssVariables(body[:darkAt]),
		"dark":  cssVariables(body[darkAt:]),
	}

	pairs := [][2]string{
		{"text-primary", "background"},
		{"text-primary", "surface"},
		{"text-secondary", "background"},
		{"text-secondary", "surface"},
		{"accent", "background"},
		{"accent", "surface"},
		{"on-accent", "accent"},
	}
	for scheme, vars := range schemes {
		for _, pair := range pairs {
			fg, bg := vars[pair[0]], vars[pair[1]]
			if fg == "" || bg == "" {
				t.Fatalf("%s: missing --%s or --%s", scheme, pair[0], pair[1])
			}
			if ratio := contrast(fg, bg); ratio < 4.5 {
				t.Errorf("%s: --%s %s on --%s %s is %.2f:1, want at least 4.5:1", scheme, pair[0], fg, pair[1], bg, ratio)
			}
		}
	}
}

var cssVariablePattern = regexp.MustCompile(`--([a-z-]+):\s*(#[0-9A-Fa-f]{6});`)

// cssVariables returns the first value of each colour custom property in css.
func cssVariables(css string) map[string]string {
	vars := map[string]string{}
	for _, m := range cssVariablePattern.FindAllStringSubmatch(css, -1) {
		if _, seen := vars[m[1]]; !seen {
			vars[m[1]] = m[2]
		}
	}
	return vars
}

// contrast is the WCAG 2 contrast ratio between two #RRGGBB colours.
func contrast(a, b string) float64 {
	la, lb := luminance(a), luminance(b)
	if la < lb {
		la, lb = lb, la
	}
	return (la + 0.05) / (lb + 0.05)
}

func luminance(hex string) float64 {
	var rgb [3]float64
	for i := range rgb {
		v, _ := strconv.ParseUint(hex[1+2*i:3+2*i], 16, 8)
		c := float64(v) / 255
		if c <= 0.04045 {
			rgb[i] = c / 12.92
		} else {
			rgb[i] = math.Pow((c+0.055)/1.055, 2.4)
		}
	}
	return 0.2126*rgb[0] + 0.7152*rgb[1] + 0.0722*rgb[2]
}

// Content sits in <main> and the links in <footer>, so assistive technology
// can jump between them.
func TestPagesHaveLandmarks(t *testing.T) {
	mux := newSiteMux(t)

	for _, path := range []string{"/", "/privacy", "/c/ABC123", "/c/AB-12"} {
		body := get(t, mux, path).Body.String()
		for _, tag := range []string{"<main>", "</main>", "<footer"} {
			if !strings.Contains(body, tag) {
				t.Errorf("%s: no %s", path, tag)
			}
		}
		if strings.Index(body, "</main>") > strings.Index(body, "<footer") {
			t.Errorf("%s: the footer is inside <main>", path)
		}
	}
}

// Every page the site serves carries the policy and the right caching and
// referrer headers for what it is. Invite pages hold a code that is the invite
// itself, so they are never cached and never leak it in a Referer.
func TestPagesSendSecurityAndCachingHeaders(t *testing.T) {
	mux := newSiteMux(t)

	const csp = "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
	for _, tc := range []struct {
		path, referrer, cache string
	}{
		{"/", "strict-origin-when-cross-origin", "public, max-age=300"},
		{"/privacy", "strict-origin-when-cross-origin", "public, max-age=300"},
		{"/nope", "strict-origin-when-cross-origin", "public, max-age=300"},
		{"/c/AB12CD", "no-referrer", "no-store"},
		{"/c/AB-12", "no-referrer", "no-store"},
		{"/.well-known/apple-app-site-association", "strict-origin-when-cross-origin", "public, max-age=3600"},
	} {
		h := get(t, mux, tc.path).Header()
		want := map[string]string{
			"Content-Security-Policy": csp,
			"X-Content-Type-Options":  "nosniff",
			"X-Frame-Options":         "DENY",
			"Referrer-Policy":         tc.referrer,
			"Cache-Control":           tc.cache,
		}
		for name, value := range want {
			if got := h.Get(name); got != value {
				t.Errorf("%s: %s is %q, want %q", tc.path, name, got, value)
			}
		}
		// httptest requests are plain HTTP, and HSTS over HTTP means nothing.
		if got := h.Get("Strict-Transport-Security"); got != "" {
			t.Errorf("%s: HSTS %q over plain HTTP", tc.path, got)
		}
	}
}

// HSTS goes out when the visitor reached the site over HTTPS, which behind the
// tunnel or a proxy is only visible in X-Forwarded-Proto.
func TestPagesSendHSTSOverHTTPS(t *testing.T) {
	mux := newSiteMux(t)

	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("X-Forwarded-Proto", "https")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if got := rec.Header().Get("Strict-Transport-Security"); got != "max-age=31536000" {
		t.Fatalf("behind a proxy: HSTS %q", got)
	}

	rec = get(t, mux, "https://peard.kroper.uk/privacy")
	if got := rec.Header().Get("Strict-Transport-Security"); got != "max-age=31536000" {
		t.Fatalf("direct TLS: HSTS %q", got)
	}
}

// The superuser UI runs scripts, and the API is not a page, so neither gets the
// site's headers — including an unknown API path that falls to the catch-all.
// (A real server gives /_/ PocketBase's own, script-allowing policy; this test
// mux doesn't, so the check is that the site's never replaces it.)
func TestPocketBaseRoutesDoNotGetThePageHeaders(t *testing.T) {
	mux := newSiteMux(t)

	for _, path := range []string{"/api/health", "/api/nope", "/_/"} {
		req := httptest.NewRequest("GET", path, nil)
		req.Header.Set("X-Forwarded-Proto", "https")
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		h := rec.Header()
		if got := h.Get("Content-Security-Policy"); strings.Contains(got, "default-src 'none'") {
			t.Errorf("%s: got the site's policy %q", path, got)
		}
		for _, name := range []string{"Referrer-Policy", "Strict-Transport-Security"} {
			if got := h.Get(name); got != "" {
				t.Errorf("%s: %s is %q, want none", path, name, got)
			}
		}
	}
}

// The support page is the App Store listing's Support URL, so it has to serve,
// say how to reach somebody, and cover the account deletion Apple asks about.
func TestSupportPageServes(t *testing.T) {
	mux := newSiteMux(t)

	rec := get(t, mux, "/support")
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	for _, want := range []string{
		`href="mailto:kieran@kroper.uk"`,
		"24 hours",
		"Mute this connection",
		"Edit Widget",
		"Log a beer in Pear'd",
		"Delete account",
		"Send Beta Feedback",
		"<main>",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("support page is missing %q", want)
		}
	}
	if got := rec.Header().Get("Cache-Control"); got != "public, max-age=300" {
		t.Errorf("Cache-Control %q, want the static pages' short public cache", got)
	}
}

// Every page links the support page from the shared footer.
func TestEveryPageLinksSupport(t *testing.T) {
	mux := newSiteMux(t)

	for _, path := range []string{"/", "/privacy", "/support", "/c/ABC123", "/nope"} {
		if !strings.Contains(get(t, mux, path).Body.String(), `href="/support"`) {
			t.Errorf("%s: no link to /support in the footer", path)
		}
	}
}
