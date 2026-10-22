package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Per-person, per-metric, per-day amounts from a source outside the posts
// timeline (#411).
//
// A moment is one event with one amount, but Apple Health reports a running
// daily total: 3,412 steps by nine in the morning, 8,900 by lunch. Writing that
// as posts would either double-count (each sync adds another entry) or fill the
// timeline with noise. This collection is the other shape: one row per
// (pair, user, metric, day) that a device upserts as the day advances.
//
// A row SUPERSEDES that member's posts for the same metric and day — the device
// is reporting the member's whole day, not an increment — so a connection that
// also logs steps by hand cannot count them twice. A member with no row is
// summed from their posts exactly as before.
//
// `source` says where the day came from ("health" today; the column exists so a
// second source does not need a migration). `amount` shares the post ceiling:
// one day's steps or minutes fit well inside it.
//
// Reading follows metric_targets: a member of the connection may read every row
// in it. Writing gets no collection rules, because writes go through
// PUT /api/peard/metric/day, which upserts exactly the caller's own row.
func init() {
	m.Register(func(app core.App) error {
		if _, err := app.FindCollectionByNameOrId("metric_days"); err == nil {
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

		zero, ceiling := 0.0, 1000000.0
		days := core.NewBaseCollection("metric_days")
		days.Fields.Add(
			&core.RelationField{Name: "pair", CollectionId: pairs.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.RelationField{Name: "user", CollectionId: users.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.TextField{Name: "metric", Required: true, Max: 40},
			// The member's own calendar day, `YYYY-MM-DD`. A string rather than a
			// date field: it is a day, not an instant, and a stored date would
			// acquire a timezone the value does not have.
			&core.TextField{Name: "day", Required: true, Max: 10},
			&core.NumberField{Name: "amount", OnlyInt: true, Min: &zero, Max: &ceiling},
			&core.TextField{Name: "source", Max: 20},
			&core.AutodateField{Name: "created", OnCreate: true},
			&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
		)
		// One total per member per metric per day: the device upserts it.
		days.AddIndex("idx_metric_days_pair_user_metric_day", true, "pair, user, metric, day", "")

		member := "pair.pair_members_via_pair.user ?= @request.auth.id"
		days.ListRule = types.Pointer(member)
		days.ViewRule = types.Pointer(member)

		if err := app.Save(days); err != nil {
			return fmt.Errorf("save metric_days: %w", err)
		}
		return nil
	}, func(app core.App) error {
		days, err := app.FindCollectionByNameOrId("metric_days")
		if err != nil {
			return nil
		}
		return app.Delete(days)
	})
}
