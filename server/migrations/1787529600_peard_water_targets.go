package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// Per-person daily water targets, shared across a connection (#335).
//
// A target is a fact about a person in a connection, so it lives on the
// membership row — the same place `muted` does — as two whole numbers of
// millilitres: the daily minimum and the recommended amount (the goal). Zero is
// how PocketBase stores an unset number and is read as "no explicit target":
// readers fall back to the built-in amounts, and an app that has never heard of
// the fields draws exactly what it drew before.
//
// Reading needs nothing new. The `pair_members` ListRule already shows a member
// every row of every connection they are in, so both people see each other's
// targets through it, and the recap route returns them alongside the streak.
//
// Writing deliberately gets no UpdateRule, for the reason the muting migration
// gives: rules cannot restrict which fields an update touches, so the rule that
// let a member set their target would let them rewrite their own `role`, or
// repoint `pair`. Targets are written through POST /api/peard/water/target,
// which sets exactly these two fields on the caller's own membership.
//
// The ceiling is WaterAmount.maximum on the client and recap.maxWaterTarget on
// the server, repeated here so a write that never meets the route cannot store
// nonsense.
func init() {
	m.Register(func(app core.App) error {
		members, err := app.FindCollectionByNameOrId("pair_members")
		if err != nil {
			return fmt.Errorf("find pair_members: %w", err)
		}
		minTarget, maxTarget := 0.0, 5000.0
		changed := false
		for _, name := range []string{"water_minimum", "water_recommended"} {
			if members.Fields.GetByName(name) != nil {
				continue
			}
			members.Fields.Add(&core.NumberField{Name: name, OnlyInt: true, Min: &minTarget, Max: &maxTarget})
			changed = true
		}
		if !changed {
			return nil
		}
		if err := app.Save(members); err != nil {
			return fmt.Errorf("save pair_members: %w", err)
		}
		return nil
	}, func(app core.App) error {
		members, err := app.FindCollectionByNameOrId("pair_members")
		if err != nil {
			return nil
		}
		for _, name := range []string{"water_minimum", "water_recommended"} {
			members.Fields.RemoveByName(name)
		}
		return app.Save(members)
	})
}
