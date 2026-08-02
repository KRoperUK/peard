package media_test

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"peard/internal/media"
)

// The hook fires for protected fields and not for public ones. Asserted at the
// event rather than through a real download, because what matters is the
// decision — the header PocketBase would otherwise set is only applied when one
// is missing, so setting it at all is the whole behaviour.
func TestProtectedFilesAreDeclaredUncacheable(t *testing.T) {
	app, _ := newApp(t)

	rec := httptest.NewRecorder()
	event := &core.FileDownloadRequestEvent{
		RequestEvent: requestEvent(rec),
		FileField:    &core.FileField{Name: "media", Protected: true},
	}
	fire(t, app, event)

	got := rec.Header().Get("Cache-Control")
	for _, want := range []string{"private", "no-store", "max-age=0"} {
		if !strings.Contains(got, want) {
			t.Fatalf("Cache-Control %q is missing %q", got, want)
		}
	}
	if rec.Header().Get("Pragma") != "no-cache" {
		t.Fatalf("Pragma = %q", rec.Header().Get("Pragma"))
	}
}

// A public file keeps PocketBase's long cache. Avatars are served to anybody by
// design, and taking the CDN away from them would cost the connection rail a
// round trip per face for nothing.
func TestPublicFilesKeepTheirCache(t *testing.T) {
	app, _ := newApp(t)

	rec := httptest.NewRecorder()
	event := &core.FileDownloadRequestEvent{
		RequestEvent: requestEvent(rec),
		FileField:    &core.FileField{Name: "avatar", Protected: false},
	}
	fire(t, app, event)

	if got := rec.Header().Get("Cache-Control"); got != "" {
		t.Fatalf("Cache-Control = %q, want it left to PocketBase", got)
	}
}

// A file field PocketBase could not identify must not be assumed public.
func TestAnUnknownFieldIsLeftAlone(t *testing.T) {
	app, _ := newApp(t)

	rec := httptest.NewRecorder()
	event := &core.FileDownloadRequestEvent{
		RequestEvent: requestEvent(rec),
	}
	fire(t, app, event)

	if got := rec.Header().Get("Cache-Control"); got != "" {
		t.Fatalf("Cache-Control = %q, want none", got)
	}
}

// The response writer lives on the embedded router.Event, so it has to be set
// after construction rather than in the literal.
func requestEvent(rec *httptest.ResponseRecorder) *core.RequestEvent {
	e := &core.RequestEvent{}
	e.Response = rec
	e.Request = httptest.NewRequest("GET", "/", nil)
	return e
}

func fire(t *testing.T, app core.App, event *core.FileDownloadRequestEvent) {
	t.Helper()
	if err := app.OnFileDownloadRequest().Trigger(event, func(e *core.FileDownloadRequestEvent) error {
		return nil
	}); err != nil {
		t.Fatalf("trigger: %v", err)
	}
}

func newApp(t *testing.T) (core.App, http.Handler) {
	t.Helper()
	dir, err := os.MkdirTemp("", "peard-media-test-*")
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
	media.Register(app)
	return app, nil
}
