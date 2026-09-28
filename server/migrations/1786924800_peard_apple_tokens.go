package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// Where the Sign in with Apple refresh token is kept, so deleting an account
// can revoke it (see internal/auth/apple_tokens.go).
//
// A collection of its own rather than a hidden field on `users`. Every rule is
// left nil, so no client — not even the token's owner — can list, view, create,
// update or filter on it; only a superuser and the server can. A field on
// `users` would share that record's rules and every path that returns or saves
// it (the sign-in response, the profile routes, the export), and staying safe
// would depend on each of them honouring the hidden flag.
//
// `user` cascades, so the row goes with the account. The deletion hook reads
// it before that happens.
func init() {
	m.Register(func(app core.App) error {
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return fmt.Errorf("find users: %w", err)
		}
		if _, err := app.FindCollectionByNameOrId("apple_tokens"); err == nil {
			return nil
		}
		tokens := core.NewBaseCollection("apple_tokens")
		tokens.Fields.Add(
			&core.RelationField{Name: "user", CollectionId: users.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			// Hidden as well, so a record serialised anywhere outside a
			// superuser request (PocketBase unhides for superusers) leaves the
			// token out.
			&core.TextField{Name: "refresh_token", Required: true, Max: 2048, Hidden: true},
			&core.AutodateField{Name: "created", OnCreate: true},
			&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
		)
		tokens.AddIndex("idx_apple_tokens_user", true, "user", "")
		return app.Save(tokens)
	}, func(app core.App) error {
		if tokens, err := app.FindCollectionByNameOrId("apple_tokens"); err == nil {
			return app.Delete(tokens)
		}
		return nil
	})
}
