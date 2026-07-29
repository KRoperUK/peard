package migrations

import (
	"fmt"
	"strings"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// Idempotency key for queued sends.
//
// The app now writes a moment to an on-device queue before attempting the
// request, so a tap with no signal is kept rather than discarded. That introduces
// a failure mode a fire-and-forget client never had: the request reaches the
// server and the record is created, but the response is lost — the tunnel, the
// lift, the app being killed. On the next flush the queue would send it again and
// the moment would be tallied twice.
//
// `client_id` is the queue's own id for the send, carried on the record. The
// unique index turns the duplicate into a 400, which the client classifies as
// permanent and drops from the queue — exactly the right outcome, because the
// moment is already recorded.
//
// The index is partial (`client_id != ”`) because every row that predates this
// migration has an empty value, and in SQLite ” is a value like any other: a
// plain unique index would reject the second such row.
func init() {
	m.Register(func(app core.App) error {
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return fmt.Errorf("find posts: %w", err)
		}

		changed := false
		if posts.Fields.GetByName("client_id") == nil {
			// A UUID string is 36 characters; 60 leaves room without inviting
			// arbitrary payloads.
			posts.Fields.Add(&core.TextField{Name: "client_id", Max: 60})
			changed = true
		}
		if !hasIndex(posts, "idx_posts_client_id") {
			posts.AddIndex("idx_posts_client_id", true, "client_id", "client_id != ''")
			changed = true
		}
		if changed {
			if err := app.Save(posts); err != nil {
				return fmt.Errorf("save posts: %w", err)
			}
		}
		return nil
	}, func(app core.App) error {
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return nil
		}
		posts.RemoveIndex("idx_posts_client_id")
		if posts.Fields.GetByName("client_id") != nil {
			posts.Fields.RemoveByName("client_id")
		}
		return app.Save(posts)
	})
}

// hasIndex reports whether the collection already declares an index of this
// name. PocketBase stores indexes as CREATE INDEX statements.
func hasIndex(collection *core.Collection, name string) bool {
	for _, statement := range collection.Indexes {
		if strings.Contains(statement, name) {
			return true
		}
	}
	return false
}
