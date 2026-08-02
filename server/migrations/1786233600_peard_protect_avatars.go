package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// Stop serving profile photos to anyone who has the URL.
//
// The other half of 1786147200_peard_protect_media.go. That one protected
// `posts.media`; avatars were deliberately left alone, and the reasoning in
// 1785628800_peard_avatars.go was sound as far as it went: `users.ViewRule` is
// `id = @request.auth.id`, so protecting `users.avatar` would have hidden it
// from precisely the people who need it.
//
// The obvious fix — widening `users.ViewRule` to "shares a connection with me"
// — is the wrong one. That rule governs reading the whole record, and the
// record holds `phone` (a raw phone number), `email_hash` and `phone_hash`.
// Trading a readable avatar for a readable phone number is not a trade worth
// making, and three accounts have `emailVisibility` set, which would hand over
// their addresses too.
//
// PocketBase distinguishes the two. Before serving a protected file it
// evaluates the view rule with `@request.context = "protectedFile"`, so one
// rule can answer "who may read this record" and "who may read its files"
// differently. Reading a user record stays restricted to that user. Reading a
// user's avatar opens to the people who share a connection with them — which is
// exactly who the app draws it for, and exactly what the privacy policy says.
//
// `pairs.avatar` needs no such care: `pairs.ViewRule` is already
// `pair_members_via_pair.user ?= @request.auth.id`.
func init() {
	m.Register(func(app core.App) error {
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		rule := `@request.auth.id != "" && (` +
			`id = @request.auth.id` +
			` || (@request.context = "protectedFile"` +
			` && pair_members_via_user.pair.pair_members_via_pair.user ?= @request.auth.id)` +
			`)`
		users.ViewRule = &rule
		if field, ok := users.Fields.GetByName("avatar").(*core.FileField); ok {
			field.Protected = true
		}
		if err := app.Save(users); err != nil {
			return err
		}

		pairs, err := app.FindCollectionByNameOrId("pairs")
		if err != nil {
			return err
		}
		if field, ok := pairs.Fields.GetByName("avatar").(*core.FileField); ok {
			field.Protected = true
		}
		return app.Save(pairs)
	}, func(app core.App) error {
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		rule := `@request.auth.id != "" && (id = @request.auth.id)`
		users.ViewRule = &rule
		if field, ok := users.Fields.GetByName("avatar").(*core.FileField); ok {
			field.Protected = false
		}
		if err := app.Save(users); err != nil {
			return err
		}

		pairs, err := app.FindCollectionByNameOrId("pairs")
		if err != nil {
			return err
		}
		if field, ok := pairs.Fields.GetByName("avatar").(*core.FileField); ok {
			field.Protected = false
		}
		return app.Save(pairs)
	})
}
