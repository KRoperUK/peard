package migrations

import (
	"fmt"

	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

// Where each device is, so the weekly recap arrives on Sunday evening there
// rather than at 18:00 UTC.
//
// On the device rather than the user because the recap is delivered per device
// anyway, and because the app already rewrites its device row at the start of
// every session — the lightest existing call that can carry it, and one that
// keeps the zone current for somebody who travels. A user with no devices gets
// no push, so has no zone worth storing.
//
// The pattern is internal/zone's, repeated here so a migration never changes
// meaning when that package does. Empty is allowed: rows written by builds that
// predate the field, which the recap treats as UTC.
func init() {
	m.Register(func(app core.App) error {
		devices, err := app.FindCollectionByNameOrId("devices")
		if err != nil {
			return fmt.Errorf("find devices: %w", err)
		}
		if devices.Fields.GetByName("time_zone") == nil {
			devices.Fields.Add(&core.TextField{
				Name:    "time_zone",
				Max:     64,
				Pattern: `^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$`,
			})
		}
		return app.Save(devices)
	}, func(app core.App) error {
		devices, err := app.FindCollectionByNameOrId("devices")
		if err != nil {
			return err
		}
		devices.Fields.RemoveByName("time_zone")
		return app.Save(devices)
	})
}
