package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

// The initial migration built its collections with core.NewBaseCollection,
// which does not add the `created` / `updated` autodate fields. Without them:
//
//   - `?sort=-created` is rejected with 400 (the app's timeline and
//     "first matching record" queries both use it),
//   - records carry no timestamp, so tallies per day/week/month, the
//     elapsed-time labels, and internal/widget's `created >= today` count all
//     have nothing to work with.
//
// This migration adds both fields to every Pear'd collection and backfills
// existing rows so no record is left with an empty timestamp.
func init() {
	m.Register(func(app core.App) error {
		collections := []string{
			"pairs",
			"pair_members",
			"posts",
			"reactions",
			"pair_invites",
			"devices",
			"widget_tokens",
		}

		now := types.NowDateTime().String()

		for _, name := range collections {
			col, err := app.FindCollectionByNameOrId(name)
			if err != nil {
				return fmt.Errorf("find collection %s: %w", name, err)
			}

			if col.Fields.GetByName("created") == nil {
				col.Fields.Add(&core.AutodateField{Name: "created", OnCreate: true})
			}
			if col.Fields.GetByName("updated") == nil {
				col.Fields.Add(&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true})
			}
			if err := app.Save(col); err != nil {
				return fmt.Errorf("save collection %s: %w", name, err)
			}

			// Existing rows get the column default (empty), which would decode
			// as "no timestamp" on the client. Stamp them once.
			for _, field := range []string{"created", "updated"} {
				query := fmt.Sprintf(
					"UPDATE {{%s}} SET [[%s]] = {:now} WHERE [[%s]] = '' OR [[%s]] IS NULL",
					name, field, field, field,
				)
				if _, err := app.DB().NewQuery(query).Bind(map[string]any{"now": now}).Execute(); err != nil {
					return fmt.Errorf("backfill %s.%s: %w", name, field, err)
				}
			}
		}

		// The posts index is named for (pair, created) but only covered pair;
		// now that created exists, make it match its name so the timeline query
		// is served by the index.
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return err
		}
		posts.RemoveIndex("idx_posts_pair_created")
		posts.AddIndex("idx_posts_pair_created", false, "pair, created", "")
		if err := app.Save(posts); err != nil {
			return fmt.Errorf("reindex posts: %w", err)
		}

		return nil
	}, func(app core.App) error {
		collections := []string{
			"pairs",
			"pair_members",
			"posts",
			"reactions",
			"pair_invites",
			"devices",
			"widget_tokens",
		}
		for _, name := range collections {
			col, err := app.FindCollectionByNameOrId(name)
			if err != nil {
				continue
			}
			for _, field := range []string{"created", "updated"} {
				if f := col.Fields.GetByName(field); f != nil {
					col.Fields.RemoveByName(field)
				}
			}
			if err := app.Save(col); err != nil {
				return err
			}
		}
		return nil
	})
}
