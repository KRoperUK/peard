package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Groups and custom moments.
//
// The initial schema already used a many-to-many `pair_members` join table, so
// a user belonging to several connections — and a connection holding more than
// two people — needs no data migration. What was missing:
//
//   - `pairs` had no UpdateRule, so a group could never be named by a client
//     even though the `name` field existed.
//   - `pair_invites` was always "create a new pair", so there was no way to
//     invite somebody into an existing group.
//   - custom moments were writable (`posts.event_kind` is free text) but not
//     discoverable: the other members of a connection had no way to learn that
//     a kind exists, or what emoji and label to draw for it.
//
// `moment_kinds` closes that last gap: one row per custom moment per
// connection, so every member sees the same catalogue.
func init() {
	m.Register(func(app core.App) error {
		usersCol, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return fmt.Errorf("find users: %w", err)
		}
		pairs, err := app.FindCollectionByNameOrId("pairs")
		if err != nil {
			return fmt.Errorf("find pairs: %w", err)
		}

		// --- pairs: members may rename their connection ---
		// Creation stays closed: pairs are only created by /api/peard/pairs/accept.
		pairs.UpdateRule = types.Pointer("pair_members_via_pair.user ?= @request.auth.id")
		if err := app.Save(pairs); err != nil {
			return fmt.Errorf("save pairs: %w", err)
		}

		// --- pair_invites: an invite may target an existing connection ---
		invites, err := app.FindCollectionByNameOrId("pair_invites")
		if err != nil {
			return fmt.Errorf("find pair_invites: %w", err)
		}
		if invites.Fields.GetByName("pair") == nil {
			invites.Fields.Add(&core.RelationField{
				Name:          "pair",
				CollectionId:  pairs.Id,
				CascadeDelete: true,
				MaxSelect:     1,
			})
			if err := app.Save(invites); err != nil {
				return fmt.Errorf("save pair_invites: %w", err)
			}
		}

		// --- moment_kinds: the per-connection custom moment catalogue ---
		if _, err := app.FindCollectionByNameOrId("moment_kinds"); err != nil {
			kinds := core.NewBaseCollection("moment_kinds")
			kinds.Fields.Add(
				&core.RelationField{Name: "pair", CollectionId: pairs.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
				// Matches posts.event_kind, which is what a kind row describes.
				&core.TextField{Name: "slug", Required: true, Max: 40},
				&core.TextField{Name: "emoji", Required: true, Max: 16},
				&core.TextField{Name: "label", Required: true, Max: 40},
				&core.RelationField{Name: "created_by", CollectionId: usersCol.Id, CascadeDelete: false, MaxSelect: 1},
				&core.AutodateField{Name: "created", OnCreate: true},
				&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
			)
			// One row per kind per connection; the client upserts on this.
			kinds.AddIndex("idx_moment_kinds_pair_slug", true, "pair, slug", "")

			member := "pair.pair_members_via_pair.user ?= @request.auth.id"
			kinds.ListRule = types.Pointer(member)
			kinds.ViewRule = types.Pointer(member)
			// Any member may add a kind, and it must be attributed to them.
			kinds.CreateRule = types.Pointer("created_by = @request.auth.id && " + member)
			// Renaming or re-emoji-ing is a shared decision, so any member may
			// do it; removal is limited to whoever added it.
			kinds.UpdateRule = types.Pointer(member)
			kinds.DeleteRule = types.Pointer("created_by = @request.auth.id")
			if err := app.Save(kinds); err != nil {
				return fmt.Errorf("save moment_kinds: %w", err)
			}
		}

		return nil
	}, func(app core.App) error {
		if kinds, err := app.FindCollectionByNameOrId("moment_kinds"); err == nil {
			if err := app.Delete(kinds); err != nil {
				return err
			}
		}
		if invites, err := app.FindCollectionByNameOrId("pair_invites"); err == nil {
			if invites.Fields.GetByName("pair") != nil {
				invites.Fields.RemoveByName("pair")
				if err := app.Save(invites); err != nil {
					return err
				}
			}
		}
		if pairs, err := app.FindCollectionByNameOrId("pairs"); err == nil {
			pairs.UpdateRule = nil
			if err := app.Save(pairs); err != nil {
				return err
			}
		}
		return nil
	})
}
