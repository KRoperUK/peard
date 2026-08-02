package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// An address other people would actually recognise, for contact matching.
//
// Sign in with Apple can hand back a private relay address —
// `something@privaterelay.appleid.com` — and that address is generated per
// app, per account. Nobody has it in their contacts, because it has never been
// anybody's address. Contact matching hashes `users.email`, so those accounts
// could turn discoverability on, add a phone number, and still never be found
// by the one identifier most people are looked up by.
//
// `contact_email` is what to hash instead when it is set. The account's own
// email is untouched: it is what Apple gave us, it is where mail goes, and
// changing it to make matching work would be fixing the wrong field.
//
// Not restricted to relay accounts at the schema level. Somebody who signed up
// with a work address and is known by a personal one has the same problem, and
// a column that only sometimes applies is harder to reason about than one that
// always means "the address to match on, if it differs".
func init() {
	m.Register(func(app core.App) error {
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		if users.Fields.GetByName("contact_email") == nil {
			users.Fields.Add(&core.EmailField{Name: "contact_email"})
		}
		return app.Save(users)
	}, func(app core.App) error {
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		users.Fields.RemoveByName("contact_email")
		return app.Save(users)
	})
}
