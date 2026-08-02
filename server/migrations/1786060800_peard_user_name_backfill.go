package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// Fill the stock `name` field from `display_name` for accounts that already
// exist.
//
// Pear'd never writes `name` — the app's own field is `display_name`, added by
// the init migration. But PocketBase's admin console labels a relation with
// `name`, so every pair_members row, post and reaction rendered as a bare
// record id: the console was unusable for the one thing it is best at, which is
// following relations while working out what happened.
//
// `registerNameMirror` in internal/profile keeps it in step from here on. This
// is only the accounts that predate it.
//
// Raw SQL rather than loading and saving each record: a save would run the
// users collection's validators and hooks over rows this migration has no
// business touching otherwise, and there is nothing here worth that risk.
func init() {
	m.Register(func(app core.App) error {
		_, err := app.DB().NewQuery(`
			UPDATE users
			SET name = display_name
			WHERE (name IS NULL OR name = '')
			  AND display_name IS NOT NULL
			  AND display_name != ''
		`).Execute()
		return err
	}, func(app core.App) error {
		// Down leaves the names in place. Emptying them would be a second
		// wrong answer, not a return to the first: nothing else reads this
		// field, and a console that shows ids again helps nobody.
		return nil
	})
}
