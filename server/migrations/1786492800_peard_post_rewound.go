package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// Whether somebody *chose* a moment's time, as opposed to how late it arrived.
//
// 1786406400_peard_post_happened_at derived the "Rewound" chip from the gap
// between `created` and `happened_at`, which was right while a picked time was
// the only way to open that gap. A moment queued in a basement and sent two
// hours later opens it too, and should land at the time it was tapped without
// being labelled as filled in after the fact. So the chip gets a field that
// means exactly one thing: the person picked this time.
//
// Every gap before this migration was a picked time, so the backfill is the old
// rule — more than a minute between the two. `replace(..., 'Z', ”)` because
// SQLite's date functions return null for PocketBase's trailing Z.
func init() {
	m.Register(func(app core.App) error {
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return fmt.Errorf("find posts: %w", err)
		}
		if posts.Fields.GetByName("rewound") == nil {
			posts.Fields.Add(&core.BoolField{Name: "rewound"})
		}
		if err := app.Save(posts); err != nil {
			return fmt.Errorf("save posts: %w", err)
		}

		_, err = app.DB().NewQuery(`
			UPDATE {{posts}} SET [[rewound]] = TRUE
			WHERE (julianday(replace([[created]], 'Z', '')) - julianday(replace([[happened_at]], 'Z', ''))) * 86400 > 60
		`).Execute()
		if err != nil {
			return fmt.Errorf("backfill posts.rewound: %w", err)
		}
		return nil
	}, func(app core.App) error {
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return err
		}
		posts.Fields.RemoveByName("rewound")
		return app.Save(posts)
	})
}
