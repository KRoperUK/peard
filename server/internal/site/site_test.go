package site_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

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

	for _, path := range []string{"/", "/privacy"} {
		if code := get(t, mux, path).Code; code != http.StatusOK {
			t.Fatalf("%s: got %d, want 200", path, code)
		}
	}
}
