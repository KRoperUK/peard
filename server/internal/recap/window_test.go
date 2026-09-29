package recap

import (
	"testing"
	"time"
)

// Without a supplied start, the window opens at midnight in the caller's zone
// (#268), recapDays back.
func TestWindowStartWithoutBoundaryUsesTheCallersZone(t *testing.T) {
	tokyo, err := time.LoadLocation("Asia/Tokyo")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 3, 18, 10, 0, 0, 0, time.UTC).In(tokyo) // 19:00 Wed in Tokyo
	want := time.Date(2026, 3, 18, 0, 0, 0, 0, tokyo).AddDate(0, 0, -(recapDays - 1)).UTC().Format(pocketBaseLayout)
	if got := windowStartAt("", now); got != want {
		t.Fatalf("window start = %s, want %s", got, want)
	}
}
