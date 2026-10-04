package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// A post can answer a photo: a comment typed under it, or a photo sent back.
//
// `reply_to` points at the photo being answered. The reply is otherwise an
// ordinary post — a note for words, a photo for a photo — so it lands in the
// timeline, the push fan-out and the unread count by the routes every post
// already takes, and a client that has never heard of the field draws it as
// the note or photo it is.
//
// Not a cascade: deleting a photo leaves the answers to it standing, the same
// as taking back a moment leaves the replies typed into its notification.
// PocketBase empties the relation instead, and a reply whose photo has gone
// reads as a note on its own, which is what it then is.
func init() {
	m.Register(func(app core.App) error {
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return fmt.Errorf("find posts: %w", err)
		}
		if posts.Fields.GetByName("reply_to") != nil {
			return nil
		}
		posts.Fields.Add(&core.RelationField{Name: "reply_to", CollectionId: posts.Id, MaxSelect: 1})
		posts.AddIndex("idx_posts_reply_to", false, "reply_to", "reply_to != ''")
		if err := app.Save(posts); err != nil {
			return fmt.Errorf("save posts: %w", err)
		}
		return nil
	}, func(app core.App) error {
		posts, err := app.FindCollectionByNameOrId("posts")
		if err != nil {
			return err
		}
		posts.RemoveIndex("idx_posts_reply_to")
		posts.Fields.RemoveByName("reply_to")
		return app.Save(posts)
	})
}
