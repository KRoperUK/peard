package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// Per-connection read state, so "unread" can mean unread.
//
// The push badge counted moments other people posted in the last 24 hours,
// which its own comment admitted was "there is this much new" rather than a
// count of anything. It read 3 when you had already seen all three, and 0 the
// day after when you had seen none of them.
//
// `last_seen_at` goes on `pair_members` rather than into a `pair_reads`
// collection of its own. That row already is the (user, pair) pair this needs to
// key on, already carries exactly this shape of state in `muted`, and is already
// loaded by every route that would want the read stamp — a separate collection
// would add a join to answer a question the existing row can answer directly,
// and a second thing to clean up when a membership goes.
//
// Optional rather than defaulted to "now": an absent stamp means "never opened
// this connection", which the unread count reads as "since you joined" (the
// membership's own `created`). Backfilling it to the migration date would have
// told every existing user that everything before today was read, which is true
// for most of them and a silent loss for anyone with something waiting.
//
// No client-writable rule, for the reason spelled out in
// 1785369600_peard_muting.go: PocketBase rules cannot restrict which fields an
// update touches, so a rule permitting `last_seen_at` would also permit `role`
// and `pair`. Stamping goes through POST /api/peard/connections/seen, which
// writes this one field.
func init() {
	m.Register(func(app core.App) error {
		members, err := app.FindCollectionByNameOrId("pair_members")
		if err != nil {
			return fmt.Errorf("find pair_members: %w", err)
		}
		if members.Fields.GetByName("last_seen_at") == nil {
			members.Fields.Add(&core.DateField{Name: "last_seen_at"})
			if err := app.Save(members); err != nil {
				return fmt.Errorf("save pair_members: %w", err)
			}
		}
		return nil
	}, func(app core.App) error {
		members, err := app.FindCollectionByNameOrId("pair_members")
		if err != nil {
			return nil
		}
		if members.Fields.GetByName("last_seen_at") != nil {
			members.Fields.RemoveByName("last_seen_at")
			return app.Save(members)
		}
		return nil
	})
}
