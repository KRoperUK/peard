package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"

	"peard/internal/widget"
)

// Widget tokens minted before #340 carry no expiry, so resolveToken honours
// them forever and pruneWidgetTokens never retires them: a leaked legacy
// token never dies. Going forward every mint sets expires, but rows already
// stored need bounding: each gets a fresh TTL from migration time, so legacy
// installs survive one renewal window and then expire like everything else.
func init() {
	m.Register(func(app core.App) error {
		_, err := widget.BackfillWidgetTokenExpiry(app)
		return err
	}, func(app core.App) error {
		// A no-op: nothing records which expiries this migration set, and
		// clearing them would recreate immortal tokens.
		return nil
	})
}
