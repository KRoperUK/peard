package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"

	"peard/internal/contacts"
)

// Adds what "find friends from your contacts" needs: an optional phone
// number nothing has asked for before now, a discoverable flag (opt-in,
// default off — searching your own contacts needs no opt-in, appearing in
// someone else's results does), and a hash of each so a match request never
// has to compare against plaintext email or phone. See internal/contacts for
// the hash — imported rather than duplicated here, because the whole point
// of a backfill is that it produces the same hash the live record hooks
// will, and a copy could quietly drift from that.
func init() {
	m.Register(func(app core.App) error {
		usersCol, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}

		usersCol.Fields.Add(
			&core.TextField{Name: "phone", Max: 32},
			&core.BoolField{Name: "discoverable"},
			&core.TextField{Name: "email_hash", Max: 64},
			&core.TextField{Name: "phone_hash", Max: 64},
		)
		usersCol.AddIndex("idx_users_email_hash", false, "email_hash", "")
		usersCol.AddIndex("idx_users_phone_hash", false, "phone_hash", "")
		if err := app.Save(usersCol); err != nil {
			return err
		}

		// Backfill: every existing account gets an email_hash so it is
		// matchable the moment it opts into discoverable, without needing to
		// re-save its email first. No existing account has a phone yet.
		users, err := app.FindAllRecords("users")
		if err != nil {
			return err
		}
		for _, user := range users {
			user.Set("email_hash", contacts.HashEmail(user.GetString("email")))
			if err := app.Save(user); err != nil {
				return err
			}
		}
		return nil
	}, func(app core.App) error {
		usersCol, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		for _, name := range []string{"phone", "discoverable", "email_hash", "phone_hash"} {
			usersCol.Fields.RemoveByName(name)
		}
		return app.Save(usersCol)
	})
}
