package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Per-person, per-metric daily targets (#386).
//
// The generalisation of the two water columns on pair_members
// (1787529600_peard_water_targets): where water stores one member's minimum and
// recommended as fixed columns, an extensible metric system needs a target per
// (member, metric) — water, steps, exercise, or a connection's own tracked
// kind. That is a row shape, not a column shape, so it is its own collection
// rather than an ever-growing set of <metric>_minimum / <metric>_goal columns.
//
// A target is still a fact about a person in a connection: the row carries the
// pair, the user, the metric slug (the posts.event_kind it measures), a daily
// minimum and a goal. Both zero is "none stored", read as the metric's built-in
// defaults — the same convention the water columns use, so a metric with no row
// behaves exactly as water did before anyone set a target.
//
// Reading: the ListRule shows a member every target row in any connection they
// belong to, so everybody sees everybody's, as the recap already shows water's.
//
// Writing gets no CreateRule/UpdateRule beyond membership, for the reason the
// water and muting migrations give: a rule cannot restrict which fields a write
// touches. Targets are written through POST /api/peard/metric/target, which
// upserts exactly these fields on the caller's own (pair, user, metric) row.
//
// This is ADDITIVE: the water columns and /api/peard/water/target stay exactly
// as they are. Water continues to work unchanged; this collection is the path a
// generalised reader will prefer once it exists, with the water columns as the
// fallback.
func init() {
	m.Register(func(app core.App) error {
		if _, err := app.FindCollectionByNameOrId("metric_targets"); err == nil {
			return nil // already created
		}
		pairs, err := app.FindCollectionByNameOrId("pairs")
		if err != nil {
			return fmt.Errorf("find pairs: %w", err)
		}
		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return fmt.Errorf("find users: %w", err)
		}

		minTarget, maxTarget := 0.0, 1000000.0
		targets := core.NewBaseCollection("metric_targets")
		targets.Fields.Add(
			&core.RelationField{Name: "pair", CollectionId: pairs.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.RelationField{Name: "user", CollectionId: users.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.TextField{Name: "metric", Required: true, Max: 40},
			&core.NumberField{Name: "minimum", OnlyInt: true, Min: &minTarget, Max: &maxTarget},
			&core.NumberField{Name: "goal", OnlyInt: true, Min: &minTarget, Max: &maxTarget},
			&core.AutodateField{Name: "created", OnCreate: true},
			&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
		)
		// One target per member per metric in a connection.
		targets.AddIndex("idx_metric_targets_pair_user_metric", true, "pair, user, metric", "")

		// A member of the connection may read every target row in it.
		member := "pair.pair_members_via_pair.user ?= @request.auth.id"
		targets.ListRule = types.Pointer(member)
		targets.ViewRule = types.Pointer(member)
		// No create/update/delete rules: writes go through the metric/target
		// route, which the route-level RequireAuth + membership check guards.

		if err := app.Save(targets); err != nil {
			return fmt.Errorf("save metric_targets: %w", err)
		}
		return nil
	}, func(app core.App) error {
		targets, err := app.FindCollectionByNameOrId("metric_targets")
		if err != nil {
			return nil
		}
		return app.Delete(targets)
	})
}
