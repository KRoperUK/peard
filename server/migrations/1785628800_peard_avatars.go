package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// Profile photos for people and for connections.
//
// `users.avatar` already exists on PocketBase's default auth collection, but with
// `thumbs: null` — so the only thing servable is the original upload, and a
// connection rail drawing a dozen 40pt circles would pull a dozen full-size
// photos. Thumbs are added here rather than a new field so nothing that already
// set an avatar through the dashboard is orphaned.
//
// `pairs.avatar` is new: a group is a thing with a face, and the rail is
// unreadable when every group is the same grey circle.
//
// Both fields are deliberately **unprotected**, which is how `posts.media`
// already works: PocketBase only enforces the collection's view rule on files
// when the field is protected, and `users.ViewRule` is `id = @request.auth.id`.
// A protected avatar would therefore be invisible to exactly the people who need
// to see it — everybody else in the connection. Unprotected means the URL is the
// capability; PocketBase appends a 10-character random suffix to every stored
// filename, so the path cannot be guessed from a record id alone.
func init() {
	m.Register(func(app core.App) error {
		// --- users.avatar: add thumbs, pin a maximum size ---
		usersCol, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return fmt.Errorf("find users: %w", err)
		}
		usersCol.Fields.Add(avatarField())
		if err := app.Save(usersCol); err != nil {
			return fmt.Errorf("save users: %w", err)
		}

		// --- pairs.avatar: the group photo ---
		pairs, err := app.FindCollectionByNameOrId("pairs")
		if err != nil {
			return fmt.Errorf("find pairs: %w", err)
		}
		if pairs.Fields.GetByName("avatar") == nil {
			pairs.Fields.Add(avatarField())
			if err := app.Save(pairs); err != nil {
				return fmt.Errorf("save pairs: %w", err)
			}
		}
		return nil
	}, func(app core.App) error {
		if pairs, err := app.FindCollectionByNameOrId("pairs"); err == nil {
			if pairs.Fields.GetByName("avatar") != nil {
				pairs.Fields.RemoveByName("avatar")
				if err := app.Save(pairs); err != nil {
					return err
				}
			}
		}
		// users.avatar is part of PocketBase's default collection, so it is left
		// in place; only the thumbs it gained here are dropped.
		if usersCol, err := app.FindCollectionByNameOrId("users"); err == nil {
			if field, ok := usersCol.Fields.GetByName("avatar").(*core.FileField); ok {
				field.Thumbs = nil
				if err := app.Save(usersCol); err != nil {
					return err
				}
			}
		}
		return nil
	})
}

// avatarField describes an avatar attachment. Two thumb sizes because the rail
// draws small circles and the settings screen draws a large one, and asking
// PocketBase for a size it was not told about returns the original.
func avatarField() *core.FileField {
	return &core.FileField{
		Name:      "avatar",
		MaxSelect: 1,
		MaxSize:   8 << 20,
		MimeTypes: []string{"image/jpeg", "image/png", "image/webp", "image/heic"},
		Thumbs:    []string{"128x128", "512x512"},
	}
}
