// Package version reports which build of the server is running.
//
//	GET /api/peard/status -> { ok, commit, built_at, go }
//
// This exists because "which version is deployed?" was unanswerable from
// outside the host. The app shipped features — in-app account deletion, read
// state — whose routes simply 404'd against a server that had not been
// rebuilt, and nothing about that was visible: the server was healthy, the
// routes were absent, and the only way to tell was to probe a route and infer
// it from the status code.
//
// Deliberately public. It names a commit of a public repository and a build
// time, neither of which is a secret, and requiring auth would defeat the point
// — the first thing you want to check when something behaves oddly is what is
// actually running, usually before you have a token in hand.
package version

import (
	"net/http"
	"os"
	"runtime"
	"strings"

	"github.com/pocketbase/pocketbase/core"
)

// Commit is the git revision this server was deployed from.
//
// Set at link time where the caller knew it:
//
//	-ldflags "-X peard/internal/version.Commit=$(git rev-parse --short HEAD)"
//
// Otherwise read at startup from the file the Docker build writes — see
// commitFile. That path exists because the deploy that matters does not pass
// one: Komodo clones the repository and builds, so every deployed server
// reported "unknown" while the answer was sitting in the checkout it had just
// made.
var Commit = ""

// BuiltAt is the UTC timestamp of the build, injected at link time by the
// Dockerfile during the build itself, so it needs nothing from the caller.
//
// Not the same question as Commit, and they can honestly disagree: Docker
// caches the Go build, so a push that changed nothing under server/ produces a
// new image carrying the old binary. The commit then names the revision that
// was deployed and the build time names when that binary was compiled. Both are
// true; neither is a substitute for the other.
var BuiltAt = "unknown"

// Where the Docker build leaves the revision for a binary that was not linked
// with one.
const commitFile = "/app/commit"

// Resolve settles Commit once, at startup, so the handler does no I/O.
//
// The literal "unknown" counts as unset, not as an answer. A compose file
// defaulted the build arg to that string, the linker duly baked it in, and the
// file below was never read — the fix works either way now, rather than
// depending on every caller getting the default right.
func Resolve() {
	if Commit != "" && Commit != "unknown" {
		return
	}
	if data, err := os.ReadFile(commitFile); err == nil {
		if trimmed := strings.TrimSpace(string(data)); trimmed != "" {
			Commit = trimmed
			return
		}
	}
	// Neither linked in nor written by a build. A `go run` from a developer's
	// machine, and "unknown" is the honest answer.
	Commit = "unknown"
}

func Register(app core.App) {
	Resolve()
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.GET("/api/peard/status", handler)
		return se.Next()
	})
}

func handler(e *core.RequestEvent) error {
	return e.JSON(http.StatusOK, map[string]any{
		"ok":       true,
		"commit":   Commit,
		"built_at": BuiltAt,
		"go":       runtime.Version(),
	})
}
