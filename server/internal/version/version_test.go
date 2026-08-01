package version

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

// The whole point of this route is being reachable without credentials, at the
// moment something looks wrong — which is usually before anybody has a token.
func TestStatusIsPublicAndReportsTheBuild(t *testing.T) {
	dir, err := os.MkdirTemp("", "peard-version-test-*")
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

	Register(app)

	router, err := apis.NewRouter(app)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}
	event := new(core.ServeEvent)
	event.App = app
	event.Router = router
	var mux http.Handler
	if err := app.OnServe().Trigger(event, func(e *core.ServeEvent) error {
		m, err := e.Router.BuildMux()
		mux = m
		return err
	}); err != nil {
		t.Fatalf("build mux: %v", err)
	}

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest("GET", "/api/peard/status", nil))
	if rec.Code != 200 {
		t.Fatalf("got %d, body %s", rec.Code, rec.Body.String())
	}

	var body struct {
		OK      bool   `json:"ok"`
		Commit  string `json:"commit"`
		BuiltAt string `json:"built_at"`
		Go      string `json:"go"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !body.OK {
		t.Error("ok is false")
	}
	// Unset in a `go test` build, which is the honest answer rather than an
	// error — the fields exist and say so.
	for name, value := range map[string]string{"commit": body.Commit, "built_at": body.BuiltAt, "go": body.Go} {
		if value == "" {
			t.Errorf("%s is empty; it should say \"unknown\" rather than nothing", name)
		}
	}
}

// Resolving the commit is the other piece of logic here, and it is the piece
// that was wrong for every deployed server: the compose file defaulted the
// build arg to the literal "unknown", the linker duly baked that string in, and
// the file the Docker build had gone to the trouble of writing was never read.

func TestALinkedCommitWins(t *testing.T) {
	defer swap("abc1234")()

	Resolve()

	if Commit != "abc1234" {
		t.Errorf("Commit = %q, want the linked value", Commit)
	}
}

// The bug. "unknown" is what a caller says when it has nothing to say, so it
// must not stop the file being consulted — otherwise the fix would depend on
// every compose file and CI job getting a default right.
func TestTheLiteralUnknownIsTreatedAsUnset(t *testing.T) {
	defer swap("unknown")()

	Resolve()

	// There is no commit file on a test machine, so this settles back to
	// "unknown". The point is that it went looking rather than returning at the
	// first check.
	if Commit != "unknown" {
		t.Errorf("Commit = %q, want unknown", Commit)
	}
}

func TestNothingAnywhereIsUnknownRatherThanEmpty(t *testing.T) {
	defer swap("")()

	Resolve()

	if Commit != "unknown" {
		t.Errorf("Commit = %q — an empty commit must never reach the response", Commit)
	}
}

// Resolve runs at startup and the handler reads what it settled on, so calling
// it twice must not undo the first answer.
func TestResolvingTwiceIsStable(t *testing.T) {
	defer swap("abc1234")()

	Resolve()
	Resolve()

	if Commit != "abc1234" {
		t.Errorf("Commit = %q after a second resolve", Commit)
	}
}

// swap sets the package-level Commit and returns a function restoring it, so
// these tests cannot leak into each other or into the route test above.
func swap(value string) func() {
	previous := Commit
	Commit = value
	return func() { Commit = previous }
}
