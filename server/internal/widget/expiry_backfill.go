package widget

import (
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

// BackfillWidgetTokenExpiry bounds widget tokens minted before #340, which
// have no expiry and therefore resolve forever (resolveToken only rejects a
// set date in the past). Each gets a fresh TTL from now, so legacy installs
// keep working through one renewal window instead of dying on upgrade, and
// pruneWidgetTokens retires them naturally afterwards. Returns rows touched.
func BackfillWidgetTokenExpiry(app core.App) (int, error) {
	rows, err := app.FindAllRecords("widget_tokens")
	if err != nil {
		return 0, err
	}
	now := time.Now()
	touched := 0
	for _, r := range rows {
		if !r.GetDateTime("expires").IsZero() {
			continue
		}
		r.Set("expires", now.Add(widgetTokenTTL).UTC().Format(types.DefaultDateLayout))
		if err := app.Save(r); err != nil {
			return touched, err
		}
		touched++
	}
	return touched, nil
}
