package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// Per-connection notification muting.
//
// A user may belong to 20 connections of up to 12 people each, so every post
// fans out to as many as 11 other members and a busy group can dominate the
// lock screen. `muted` is per membership rather than per user, so silencing the
// noisy group leaves the 1:1 that matters audible.
//
// No client-writable rule is added: `pair_members` has no UpdateRule and must
// not get one, because PocketBase rules cannot restrict *which* fields an update
// touches — the same rule that let a member set `muted` would let them rewrite
// their own `role`, or repoint `pair` at a connection they are not in. Muting
// therefore goes through POST /api/peard/connections/mute, which writes exactly
// this one field.
func init() {
	m.Register(func(app core.App) error {
		members, err := app.FindCollectionByNameOrId("pair_members")
		if err != nil {
			return fmt.Errorf("find pair_members: %w", err)
		}
		if members.Fields.GetByName("muted") == nil {
			members.Fields.Add(&core.BoolField{Name: "muted"})
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
		if members.Fields.GetByName("muted") != nil {
			members.Fields.RemoveByName("muted")
			return app.Save(members)
		}
		return nil
	})
}
