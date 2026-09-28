package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Where to send a photo-drop Live Activity.
//
// Two kinds of ActivityKit token, with different lifetimes, so two homes:
//
//   - `devices.activity_start_token` — the push-to-start token (iOS 17.2+). One
//     per device and activity type, it lets the server start an activity with
//     the app not running, and it lives as long as the device registration.
//   - `live_activities` — one row per running activity: the token that updates
//     *that* activity, scoped to one connection, and only worth anything while
//     the activity is. `expires` is set by the server, thirty minutes on from
//     the last photo, after which the next photo starts a fresh activity.
//
// Rows are the device owner's own, like `devices`, and creating one also needs
// membership of the connection: a token for a connection you are not in would
// be a way to receive its photos.
func init() {
	m.Register(func(app core.App) error {
		devices, err := app.FindCollectionByNameOrId("devices")
		if err != nil {
			return fmt.Errorf("find devices: %w", err)
		}
		if devices.Fields.GetByName("activity_start_token") == nil {
			devices.Fields.Add(&core.TextField{Name: "activity_start_token", Max: 512})
		}
		if err := app.Save(devices); err != nil {
			return fmt.Errorf("save devices: %w", err)
		}

		users, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}
		pairs, err := app.FindCollectionByNameOrId("pairs")
		if err != nil {
			return err
		}

		activities, _ := app.FindCollectionByNameOrId("live_activities")
		if activities == nil {
			activities = core.NewBaseCollection("live_activities")
		}
		activities.Fields.Add(
			&core.RelationField{Name: "user", CollectionId: users.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.RelationField{Name: "pair", CollectionId: pairs.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.TextField{Name: "push_token", Required: true, Max: 512},
			&core.DateField{Name: "expires"},
			&core.AutodateField{Name: "created", OnCreate: true},
			&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
		)
		activities.AddIndex("idx_live_activities_push_token", true, "push_token", "")
		activities.AddIndex("idx_live_activities_user_pair", false, "user, pair", "")

		own := authGuard + ` && user = @request.auth.id`
		member := own + ` && pair.pair_members_via_pair.user ?= @request.auth.id`
		activities.ListRule = types.Pointer(own)
		activities.ViewRule = types.Pointer(own)
		activities.CreateRule = types.Pointer(member)
		activities.UpdateRule = types.Pointer(member)
		activities.DeleteRule = types.Pointer(own)
		return app.Save(activities)
	}, func(app core.App) error {
		if activities, err := app.FindCollectionByNameOrId("live_activities"); err == nil {
			if err := app.Delete(activities); err != nil {
				return err
			}
		}
		devices, err := app.FindCollectionByNameOrId("devices")
		if err != nil {
			return err
		}
		devices.Fields.RemoveByName("activity_start_token")
		return app.Save(devices)
	})
}
