package recap

import (
	"testing"
	"time"

	"peard/internal/zone"
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

// MARK: #344 day-bucketing is IANA-aware across a DST change

// London goes forward at 01:00 GMT on 29 March 2026. A moment logged at
// 00:30 UTC that day is 00:30 GMT (before the change) — still the 29th locally.
// A moment logged the previous evening at 23:30 UTC is 23:30 GMT on the 28th.
// A fixed-offset bucketer applying the *current* (summer, +1h) offset to both
// would push the 28th's evening moment into the 29th, merging two days into one
// and silently inflating or breaking a streak. localDay must use the date's own
// offset instead.
func TestLocalDayBucketsByTheDatesOwnOffset(t *testing.T) {
	london, ok := zone.Load("Europe/London")
	if !ok {
		t.Fatal("Europe/London did not load")
	}

	cases := []struct {
		name string
		utc  string
		want string
	}{
		// Before the clocks went forward: GMT (UTC+0).
		{"evening before the change", "2026-03-28 23:30:00.000Z", "2026-03-28"},
		{"just after midnight, still GMT", "2026-03-29 00:30:00.000Z", "2026-03-29"},
		// After the change the same day: BST (UTC+1), so 23:30 UTC is 00:30 the
		// next local day.
		{"late evening in BST rolls to next day", "2026-03-29 23:30:00.000Z", "2026-03-30"},
		// A plain summer day, well inside BST.
		{"a summer midday", "2026-07-01 11:00:00.000Z", "2026-07-01"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			day, okDay := localDay(c.utc, london)
			if !okDay {
				t.Fatalf("localDay(%q) refused to parse", c.utc)
			}
			if got := day.Format("2006-01-02"); got != c.want {
				t.Errorf("localDay(%q) = %s, want %s", c.utc, got, c.want)
			}
		})
	}
}

// A timestamp without millisecond precision still buckets, since the raw rows
// can carry either form.
func TestLocalDayAcceptsSecondPrecision(t *testing.T) {
	utc, ok := zone.Load("UTC")
	if !ok {
		t.Fatal("UTC did not load")
	}
	if day, okDay := localDay("2026-03-29 12:00:00Z", utc); !okDay || day.Format("2006-01-02") != "2026-03-29" {
		t.Fatalf("localDay(second precision) = %v (ok=%v)", day, okDay)
	}
}

// runsFromDays reads the current and best consecutive-day runs from a
// newest-first list. Shared by the IANA and shift paths, so it is worth a
// direct check.
func TestRunsFromDaysReadsStreaks(t *testing.T) {
	day := func(d int) time.Time { return time.Date(2026, 3, d, 0, 0, 0, 0, time.UTC) }
	today := day(29)

	// 29, 28, 27 then a gap then 24, 23: current run 3 (reaches today), best 3.
	days := []time.Time{day(29), day(28), day(27), day(24), day(23)}
	current, best := runsFromDays(days, today)
	if current != 3 || best != 3 {
		t.Fatalf("current=%d best=%d, want 3/3", current, best)
	}

	// Newest is the day before yesterday: the current run is dead, best is the
	// longest historical run (26,25,24 = 3).
	stale := []time.Time{day(26), day(25), day(24)}
	current, best = runsFromDays(stale, today)
	if current != 0 || best != 3 {
		t.Fatalf("stale: current=%d best=%d, want 0/3", current, best)
	}

	// No days at all is no streak.
	if c, b := runsFromDays(nil, today); c != 0 || b != 0 {
		t.Fatalf("empty: current=%d best=%d, want 0/0", c, b)
	}
}
