package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// Stop serving shared photos to anyone who has the URL.
//
// `posts.media` was an unprotected file field, which in PocketBase means the
// file is served to any request at all — no session, no membership, no
// expiry. A photo shared into a connection was fetchable forever by anybody
// who came by the link, and the privacy policy says the opposite in as many
// words: "Only people you share a connection with can see your name, photo or
// moments. This is enforced by rules on the server, not only by the app."
//
// The defence was that PocketBase appends a ten-character random suffix to
// stored filenames, so the path cannot be guessed from a record id. That makes
// the URL a capability, and a capability that never expires and travels in
// screenshots, proxy logs and shared links is not the guarantee the policy
// describes.
//
// Protecting the field is the whole fix, because `posts.ViewRule` already says
// exactly the right thing — `pair.pair_members_via_pair.user ?= @request.auth.id`,
// "you are a member of the connection this post is in". PocketBase evaluates
// that rule against a file token's owner before serving a protected file, so
// the rule that governs reading the post now governs reading its bytes.
//
// Avatars are deliberately left alone. `users.ViewRule` is `id = @request.auth.id`,
// so protecting `users.avatar` would hide it from precisely the people who need
// it — everybody else in the connection — until that rule is widened to
// "shares a connection with me". That is a separate change with its own blast
// radius, and 1785628800_peard_avatars.go already records the reasoning.
func init() {
	m.Register(func(app core.App) error {
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return err
		}
		if field, ok := posts.Fields.GetByName("media").(*core.FileField); ok {
			field.Protected = true
		}
		if err := app.Save(posts); err != nil {
			return err
		}

		// File tokens are minted from the *auth* collection, and PocketBase's
		// default lifetime is three minutes. That is right for a one-off
		// download and wrong for a timeline: the token is part of the image
		// URL, so every rotation changes every URL on screen and makes the
		// whole list fetch itself again.
		//
		// Thirty minutes trades a longer-lived bearer token for not doing
		// that. It is still a token, still tied to one account, and still
		// expires — measured against what it replaces, which was no token and
		// no expiry at all, this is not the risky end of the change.
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		users.FileToken.Duration = 1800
		return app.Save(users)
	}, func(app core.App) error {
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return err
		}
		if field, ok := posts.Fields.GetByName("media").(*core.FileField); ok {
			field.Protected = false
		}
		if err := app.Save(posts); err != nil {
			return err
		}

		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		users.FileToken.Duration = 180
		return app.Save(users)
	})
}
