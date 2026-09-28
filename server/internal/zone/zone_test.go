package zone

import (
	"testing"
	"time"
)

func TestRealZonesLoad(t *testing.T) {
	for _, name := range []string{
		"UTC", "Europe/London", "America/New_York", "Asia/Kolkata",
		"America/Argentina/Buenos_Aires", "America/Port-au-Prince", "Etc/GMT+5",
	} {
		if _, ok := Load(name); !ok {
			t.Errorf("%q was refused", name)
		}
	}
}

// Anything else is refused rather than guessed at, including the two spellings
// LoadLocation takes to mean the server's own zone.
func TestAnythingElseIsRefused(t *testing.T) {
	for _, name := range []string{
		"", "Local", "Mars/Olympus_Mons", "../../etc/passwd", "/etc/localtime",
		"Europe/London ", "Europe//London", "+05:30", "Europe/London\x00",
	} {
		if _, ok := Load(name); ok {
			t.Errorf("%q was accepted", name)
		}
	}
}

// On the day the clocks go forward the day is 23 hours long, so midnight is
// not "24 hours before the next midnight".
func TestStartOfDayAcrossAClockChange(t *testing.T) {
	london, _ := Load("Europe/London")
	// 29 March 2026, 20:00 BST: the clocks went forward at 01:00 GMT that day.
	evening := time.Date(2026, 3, 29, 19, 0, 0, 0, time.UTC)

	got := StartOfDay(evening, london)

	if want := time.Date(2026, 3, 29, 0, 0, 0, 0, time.UTC); !got.Equal(want) {
		t.Fatalf("start of day %v, want %v (midnight GMT, before the change)", got.UTC(), want)
	}
}

// East of UTC the local day starts the evening before, in UTC terms.
func TestStartOfDayEastOfUTC(t *testing.T) {
	tokyo, _ := Load("Asia/Tokyo")
	// 16:00 UTC on 1 August is 01:00 on 2 August in Tokyo.
	got := StartOfDay(time.Date(2026, 8, 1, 16, 0, 0, 0, time.UTC), tokyo)

	if want := time.Date(2026, 8, 1, 15, 0, 0, 0, time.UTC); !got.Equal(want) {
		t.Fatalf("start of day %v, want %v", got.UTC(), want)
	}
}
