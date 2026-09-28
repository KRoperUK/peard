package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"

	"peard/internal/pairs"
)

// Give an owner back to every connection that has members but none.
//
// Going forward the role is handed on when the owner's membership goes — see
// ensureOwner in internal/pairs/lifecycle.go — but groups whose owner left or
// deleted their account before that are stuck: only the owner can remove
// somebody, so nobody in them can. Each gets its longest-standing member
// promoted, the same choice the hook makes.
func init() {
	m.Register(func(app core.App) error {
		_, err := pairs.BackfillGroupOwners(app)
		return err
	}, func(app core.App) error {
		// A no-op: demoting the promoted members would recreate groups nobody
		// can manage, and nothing records which owners this migration made.
		return nil
	})
}
