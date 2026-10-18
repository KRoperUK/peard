package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// `posts.amount` was added for water, and capped at five litres.
//
// Amount is no longer water's alone: a daily-progress metric counts one too
// (#386), and 8,000 steps or 45 exercise minutes are ordinary values that the
// water ceiling refused at the wire (#390). This raises the field's Max to a
// sanity ceiling — one entry cannot be absurd — while each metric's own maximum
// stays in the client's `MetricDefinition` (five litres for water).
//
// Widening is safe for everything already stored: no value accepted before is
// rejected now, and nothing is rewritten. The literal is repeated here rather
// than imported so a collection field's bound is stated where it is set, as the
// original migration did.
func init() {
	m.Register(func(app core.App) error {
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return fmt.Errorf("find posts: %w", err)
		}
		field, ok := posts.Fields.GetByName("amount").(*core.NumberField)
		if !ok {
			return nil
		}
		ceiling := 1_000_000.0
		if field.Max != nil && *field.Max >= ceiling {
			return nil
		}
		field.Max = &ceiling
		if err := app.Save(posts); err != nil {
			return fmt.Errorf("save posts: %w", err)
		}
		return nil
	}, func(app core.App) error {
		// Back to the water ceiling. Rows above it would fail the field's own
		// bound the next time they were saved, so the schema is all this restores.
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return err
		}
		field, ok := posts.Fields.GetByName("amount").(*core.NumberField)
		if !ok {
			return nil
		}
		ceiling := 5000.0
		field.Max = &ceiling
		return app.Save(posts)
	})
}
