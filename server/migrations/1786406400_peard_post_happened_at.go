package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// When a moment happened, as distinct from when the server heard about it.
//
// `created` is the server's own stamp and stays that way: unread, the badge and
// `last_seen_at` are all comparisons against it, and a moment logged late is
// still news to the people who have not seen it. `happened_at` is the time the
// moment is *about* — what the timeline sorts by and what tallies, recap and
// "last happened" count — and somebody can set it up to 24 hours back.
//
// Whether a moment was rewound is not stored: it is `created` minus
// `happened_at`, past a minute's tolerance, so the chip and the times can never
// disagree. The rules for the field live in internal/posts.
//
// Every existing row happened when it was logged, so the backfill is `created`.
func init() {
	m.Register(func(app core.App) error {
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return fmt.Errorf("find posts: %w", err)
		}
		if posts.Fields.GetByName("happened_at") == nil {
			posts.Fields.Add(&core.DateField{Name: "happened_at"})
		}
		if !hasIndex(posts, "idx_posts_pair_happened_at") {
			posts.AddIndex("idx_posts_pair_happened_at", false, "pair, happened_at", "")
		}
		if err := app.Save(posts); err != nil {
			return fmt.Errorf("save posts: %w", err)
		}

		_, err = app.DB().NewQuery(
			"UPDATE {{posts}} SET [[happened_at]] = [[created]] WHERE [[happened_at]] = '' OR [[happened_at]] IS NULL",
		).Execute()
		if err != nil {
			return fmt.Errorf("backfill posts.happened_at: %w", err)
		}
		return nil
	}, func(app core.App) error {
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return err
		}
		posts.RemoveIndex("idx_posts_pair_happened_at")
		posts.Fields.RemoveByName("happened_at")
		return app.Save(posts)
	})
}
