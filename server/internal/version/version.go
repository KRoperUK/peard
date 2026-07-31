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
	"runtime"

	"github.com/pocketbase/pocketbase/core"
)

// Commit is the git revision the binary was built from, injected at link time:
//
//	-ldflags "-X peard/internal/version.Commit=$(git rev-parse --short HEAD)"
//
// "unknown" when a build did not supply it. That is not a failure — see BuiltAt,
// which is always populated and is enough on its own to tell two builds apart.
var Commit = "unknown"

// BuiltAt is the UTC timestamp of the build, injected the same way. The
// Dockerfile computes it during the build itself, so it needs nothing from the
// deploy and is therefore always right — which makes it the field to trust when
// Commit says "unknown".
var BuiltAt = "unknown"

func Register(app core.App) {
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
