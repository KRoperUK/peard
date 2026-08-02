// Package media stops protected files being cached by anything in front of
// this server.
//
// PocketBase serves every file with `Cache-Control: max-age=2592000,
// stale-while-revalidate=86400` — thirty days. For a public file that is right.
// For a protected one it is a hole that survives the thing that protects it:
// the access check happens at the origin, and a CDN that has the bytes never
// asks the origin again.
//
// That is not hypothetical. Protecting posts.media closed the exposure at the
// origin — an unauthenticated request there returns 404 — and the reported
// photo kept returning 200 through Cloudflare, which answered
// `cf-cache-status: HIT` with an `age` of half an hour and a thirty-day
// lifetime. The file was authorised once, for one person, and then handed to
// everybody for a month.
//
// So a protected file is now declared uncacheable: `private` says only a
// browser may hold it, `no-store` says not even that, and `max-age=0` covers
// anything old enough to ignore both. PocketBase sets its own header only if
// one is missing, so setting it here wins.
package media

import (
	"github.com/pocketbase/pocketbase/core"
)

// noStore is the strictest of the three phrasings that mean "do not keep this".
// All three are sent because the thing being defended against is an
// intermediary nobody controls, and they do not all read the same one.
const noStore = "private, no-store, no-cache, max-age=0, must-revalidate"

// Register makes every protected file uncacheable by shared caches.
func Register(app core.App) {
	app.OnFileDownloadRequest().BindFunc(func(e *core.FileDownloadRequestEvent) error {
		// Only protected files. A public one — an avatar today — is served to
		// anybody by design, and taking the CDN away from it would cost the
		// connection rail a round trip per face for no gain.
		if e.FileField != nil && e.FileField.Protected {
			e.Response.Header().Set("Cache-Control", noStore)
			// Belt and braces for caches that key on Expires, and for the
			// handful that treat a missing Pragma as permission.
			e.Response.Header().Set("Pragma", "no-cache")
			e.Response.Header().Set("Expires", "0")
		}
		return e.Next()
	})
}
