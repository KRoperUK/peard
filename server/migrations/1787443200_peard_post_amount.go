package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// A moment can carry an amount: the millilitres in a glass of water.
//
// `amount` is an integer on the post, not a table of its own. Water is an
// ordinary moment — it posts, queues, notifies and tallies by the routes every
// moment takes — and the number is one more fact about it, like `note`. A
// moment that has no amount to give (a beer, a photo) leaves it at zero, which
// is how PocketBase stores an unset number, and a client that has never heard of
// the field draws the moment exactly as before.
//
// The ceiling is the same one posts.CheckAmount enforces with a sentence; it is
// repeated here so a write that never meets that hook still cannot store nonsense.
func init() {
	m.Register(func(app core.App) error {
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return fmt.Errorf("find posts: %w", err)
		}
		if posts.Fields.GetByName("amount") != nil {
			return nil
		}
		minAmount, maxAmount := 0.0, 5000.0
		posts.Fields.Add(&core.NumberField{Name: "amount", OnlyInt: true, Min: &minAmount, Max: &maxAmount})
		if err := app.Save(posts); err != nil {
			return fmt.Errorf("save posts: %w", err)
		}
		return nil
	}, func(app core.App) error {
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return err
		}
		posts.Fields.RemoveByName("amount")
		return app.Save(posts)
	})
}
