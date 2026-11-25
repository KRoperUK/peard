package widget_test

import (
	"testing"
	"time"

	"github.com/pocketbase/dbx"

	"peard/internal/widget"
)

// Legacy rows minted before #340 carry no expiry and resolve forever. The
// backfill must bound them to a fresh TTL instead.
func TestBackfillBoundsLegacyTokens(t *testing.T) {
	w := newFeedWorld(t)

	rec, err := w.app.FindFirstRecordByFilter("widget_tokens",
		"token = {:token}", dbx.Params{"token": w.token})
	if err != nil || rec == nil {
		t.Fatalf("seeded legacy token missing: %v", err)
	}
	if !rec.GetDateTime("expires").IsZero() {
		t.Fatalf("seeded token should have no expiry, got %v", rec.GetDateTime("expires"))
	}

	touched, err := widget.BackfillWidgetTokenExpiry(w.app)
	if err != nil {
		t.Fatalf("backfill: %v", err)
	}
	if touched != 1 {
		t.Fatalf("expected 1 touched row, got %d", touched)
	}

	rec, err = w.app.FindFirstRecordByFilter("widget_tokens",
		"token = {:token}", dbx.Params{"token": w.token})
	if err != nil || rec == nil {
		t.Fatalf("token missing after backfill: %v", err)
	}
	exp := rec.GetDateTime("expires")
	if exp.IsZero() {
		t.Fatalf("backfill left the expiry empty")
	}
	ttl := exp.Time().Sub(time.Now())
	if ttl < 29*24*time.Hour || ttl > 31*24*time.Hour {
		t.Fatalf("expected roughly a 30-day TTL, got %v", ttl)
	}

	if touched, err := widget.BackfillWidgetTokenExpiry(w.app); err != nil || touched != 0 {
		t.Fatalf("second backfill should touch nothing, got %d, %v", touched, err)
	}
}
