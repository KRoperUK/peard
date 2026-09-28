package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// Index the busiest lookups by user, which until now all scanned.
//
// The unique `(pair, user)` index on pair_members leads with `pair`, so it does
// nothing for `user = ?` alone — the connections list, the widget, the push
// badge and the export. devices was indexed only on `push_token`, yet every
// push looks devices up by `user`. posts had no index on `author`, which the
// export and leaving-and-deleting both filter on.
//
// Non-unique: a user has many memberships, devices and posts.
var perUserIndexes = []struct{ collection, name, column string }{
	{"pair_members", "idx_pair_members_user", "user"},
	{"devices", "idx_devices_user", "user"},
	{"posts", "idx_posts_author", "author"},
}

func init() {
	m.Register(func(app core.App) error {
		for _, idx := range perUserIndexes {
			col, err := app.FindCollectionByNameOrId(idx.collection)
			if err != nil {
				return err
			}
			col.AddIndex(idx.name, false, idx.column, "")
			if err := app.Save(col); err != nil {
				return err
			}
		}
		return nil
	}, func(app core.App) error {
		for _, idx := range perUserIndexes {
			col, err := app.FindCollectionByNameOrId(idx.collection)
			if err != nil {
				return err
			}
			col.RemoveIndex(idx.name)
			if err := app.Save(col); err != nil {
				return err
			}
		}
		return nil
	})
}
