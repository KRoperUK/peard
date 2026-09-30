package migrations

import (
	"slices"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// A 1024-square thumbnail for moment photos, for the large widget.
//
// The large widget runs the latest photo across its full width, where the
// 512-square thumbnail every other surface uses is visibly soft on a 3x
// screen. PocketBase only serves the sizes a file field lists, so the size has
// to be declared before the feed can ask for it — see widget.feedHandler.
const largeWidgetThumb = "1024x1024"

func init() {
	m.Register(func(app core.App) error {
		return setPostsMediaThumb(app, true)
	}, func(app core.App) error {
		return setPostsMediaThumb(app, false)
	})
}

func setPostsMediaThumb(app core.App, present bool) error {
	posts, err := app.FindCollectionByNameOrId("posts")
	if err != nil {
		return err
	}
	field, ok := posts.Fields.GetByName("media").(*core.FileField)
	if !ok {
		return nil
	}
	has := slices.Contains(field.Thumbs, largeWidgetThumb)
	switch {
	case present && !has:
		field.Thumbs = append(field.Thumbs, largeWidgetThumb)
	case !present && has:
		field.Thumbs = slices.DeleteFunc(field.Thumbs, func(t string) bool { return t == largeWidgetThumb })
	default:
		return nil
	}
	return app.Save(posts)
}
