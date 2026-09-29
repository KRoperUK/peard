package migrations

import (
	"slices"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// A post can be a note on its own: the "Reply" typed into a moment's
// notification. It is not an event, so it counts in no tally, recap or
// widget match — every one of those filters on `type = 'event'` — and it has
// no photo, so it is not a photo either. The words go in `note`, which every
// post already has and every client already draws.
func init() {
	m.Register(func(app core.App) error {
		return setPostTypes(app, []string{"photo", "event", "note"})
	}, func(app core.App) error {
		if _, err := app.DB().NewQuery("DELETE FROM posts WHERE type = 'note'").Execute(); err != nil {
			return err
		}
		return setPostTypes(app, []string{"photo", "event"})
	})
}

func setPostTypes(app core.App, values []string) error {
	posts, err := app.FindCollectionByNameOrId("posts")
	if err != nil {
		return err
	}
	field, ok := posts.Fields.GetByName("type").(*core.SelectField)
	if !ok {
		return nil
	}
	field.Values = slices.Clone(values)
	return app.Save(posts)
}
