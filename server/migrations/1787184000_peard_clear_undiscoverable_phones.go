package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// Drop the phone number from every account that is not discoverable.
//
// The number is only held for contact discovery, and turning discovery off now
// clears it — see settingsHandler in internal/contacts. Accounts that turned it
// off before that still hold the number and its hash; this clears them too.
func init() {
	m.Register(func(app core.App) error {
		_, err := app.DB().NewQuery(`
			UPDATE {{users}} SET [[phone]] = '', [[phone_hash]] = ''
			WHERE [[discoverable]] = FALSE AND ([[phone]] != '' OR [[phone_hash]] != '')
		`).Execute()
		return err
	}, func(app core.App) error {
		// A no-op: the numbers are gone, which is the point.
		return nil
	})
}
