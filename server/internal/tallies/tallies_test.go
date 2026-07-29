package tallies

import (
	"testing"
	"time"
)

// The window boundaries have to agree with the client's Calendar.peardTally, which
// pins the week to Monday. A mismatch would not fail anything loudly — the numbers
// would just be wrong for part of the week — so it is worth asserting.
func TestStartOfWeekIsMonday(t *testing.T) {
	cases := []struct {
		name string
		now  string
		want string
	}{
		// 2026-07-29 is a Wednesday.
		{"midweek", "2026-07-29T14:30:00Z", "2026-07-27T00:00:00Z"},
		// Monday is its own week start, from the first instant of the day.
		{"monday", "2026-07-27T00:00:01Z", "2026-07-27T00:00:00Z"},
		// Sunday belongs to the week that began the previous Monday, which is the
		// whole point of firstWeekday = 2.
		{"sunday", "2026-08-02T23:59:59Z", "2026-07-27T00:00:00Z"},
		// And the Monday after is a new week.
		{"next monday", "2026-08-03T00:00:00Z", "2026-08-03T00:00:00Z"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			now := mustParse(t, tc.now)
			got := startOfWeek(now)
			if want := mustParse(t, tc.want); !got.Equal(want) {
				t.Fatalf("startOfWeek(%s) = %s, want %s", tc.now, got, want)
			}
		})
	}
}

func TestStartOfDayAndMonth(t *testing.T) {
	now := mustParse(t, "2026-07-29T14:30:00Z")

	if got, want := startOfDay(now), mustParse(t, "2026-07-29T00:00:00Z"); !got.Equal(want) {
		t.Errorf("startOfDay = %s, want %s", got, want)
	}
	if got, want := startOfMonth(now), mustParse(t, "2026-07-01T00:00:00Z"); !got.Equal(want) {
		t.Errorf("startOfMonth = %s, want %s", got, want)
	}
}

// The client sends its own boundaries so the device's time zone decides what
// "today" means. A malformed or absent value has to fall back rather than fail the
// request, or one bad client build would take the tallies out entirely.
func TestBoundaryPrefersTheSuppliedValue(t *testing.T) {
	fallback := mustParse(t, "2026-01-01T00:00:00Z")

	got := boundary("2026-07-29T00:00:00+10:00", fallback)
	// 00:00 in UTC+10 is 14:00 the previous day in UTC.
	if want := "2026-07-28 14:00:00.000Z"; got != want {
		t.Fatalf("boundary = %q, want %q", got, want)
	}
}

func TestBoundaryFallsBackWhenMissingOrUnparseable(t *testing.T) {
	fallback := mustParse(t, "2026-01-01T00:00:00Z")
	want := "2026-01-01 00:00:00.000Z"

	for _, supplied := range []string{"", "   ", "not a date", "29/07/2026"} {
		if got := boundary(supplied, fallback); got != want {
			t.Errorf("boundary(%q) = %q, want %q", supplied, got, want)
		}
	}
}

// The format has to be the one PocketBase stores, because the comparison in the
// query is a string comparison against the `created` column.
func TestBoundaryUsesPocketBaseLayout(t *testing.T) {
	got := boundary("2026-07-29T12:34:56Z", time.Now())
	if want := "2026-07-29 12:34:56.000Z"; got != want {
		t.Fatalf("boundary = %q, want %q", got, want)
	}
}

// MARK: aggregation

func TestCountsAccumulateAcrossRows(t *testing.T) {
	var total counts
	addTo(&total, row{Day: 1, Week: 2, Month: 3, All: 4})
	addTo(&total, row{Day: 0, Week: 1, Month: 1, All: 5})

	if total != (counts{Day: 1, Week: 3, Month: 4, All: 9}) {
		t.Fatalf("unexpected totals: %+v", total)
	}
}

// `mine` in the query is 1 for the caller's own posts, 0 for everybody else's, and
// the two have to land in different buckets — that is what the home screen's two
// tally rows are.
func TestBucketSplitsByAuthorship(t *testing.T) {
	var mine, others counts

	if bucket(1, &mine, &others) != &mine {
		t.Error("mine = 1 should select the caller's bucket")
	}
	if bucket(0, &mine, &others) != &others {
		t.Error("mine = 0 should select the others bucket")
	}
}

func mustParse(t *testing.T, value string) time.Time {
	t.Helper()
	parsed, err := time.Parse(time.RFC3339, value)
	if err != nil {
		t.Fatalf("bad test date %q: %v", value, err)
	}
	return parsed
}
