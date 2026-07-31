// Pear'd server — PocketBase used as a Go framework.
//
// Everything custom lives under internal/:
//   - auth:    native Sign in with Apple + Apple's server-to-server notifications
//   - pairs:   invite / accept / leave / remove, connection list and muting
//   - profile: the caller's own display name
//   - avatars: profile photos, for a person and for a connection
//   - tallies: server-side moment counts for one connection
//   - widget:  token-authenticated feed for the WidgetKit extension
//   - push:    APNs delivery triggered by record hooks
//   - limits:  request rate limiting (PEARD_RATE_LIMITS=off disables it)
//   - version: GET /api/peard/status — which build is actually running
package main

import (
	"log"
	"os"
	"strings"

	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/plugins/migratecmd"

	peardauth "peard/internal/auth"
	"peard/internal/avatars"
	"peard/internal/contacts"
	"peard/internal/export"
	"peard/internal/limits"
	"peard/internal/pairs"
	"peard/internal/profile"
	"peard/internal/push"
	"peard/internal/site"
	"peard/internal/tallies"
	"peard/internal/version"
	"peard/internal/widget"
	_ "peard/migrations"
)

func main() {
	app := pocketbase.New()

	// Enable `migrate` cmd + automigrations when running via `go run`.
	isGoRun := strings.HasPrefix(os.Args[0], os.TempDir())
	migratecmd.MustRegister(app, app.RootCmd, migratecmd.Config{
		Automigrate: isGoRun,
	})

	// Allow overriding the public app URL (used to build media URLs for the widget).
	app.OnBootstrap().BindFunc(func(e *core.BootstrapEvent) error {
		if u := os.Getenv("PEARD_APP_URL"); u != "" {
			e.App.Settings().Meta.AppURL = strings.TrimRight(u, "/")
		}
		e.App.Settings().Meta.AppName = "Pear'd"
		return e.Next()
	})

	limits.Register(app)
	peardauth.Register(app)
	pairs.Register(app)
	profile.Register(app)
	avatars.Register(app)
	tallies.Register(app)
	widget.Register(app)
	push.Register(app)
	site.Register(app)
	export.Register(app)
	contacts.Register(app)
	version.Register(app)

	if err := app.Start(); err != nil {
		log.Fatal(err)
	}
}
