// Package zone reads the IANA time zone names clients send — the widget with
// each feed request, the app with each device registration — so that "today"
// and "Sunday evening" mean the caller's, not the server's.
//
// The container runs in UTC, and before this every day boundary the server drew
// for itself was UTC midnight: the widget's day rolled over at 7pm in New York,
// and the weekly recap reached Sydney at four on Monday morning.
package zone

import (
	"regexp"
	"time"
)

// namePattern admits the shape of an IANA name and nothing else: letters,
// digits, `_`, `+` and `-` in `/`-separated parts, like `America/Port-au-Prince`
// or `Etc/GMT+5`. time.LoadLocation already refuses paths that climb out of the
// zoneinfo directory, but a name from a client is checked here first anyway, so
// it only ever looks up something shaped like a zone.
var namePattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$`)

// MaxNameLength bounds a stored name. The longest in the database today is
// about thirty characters.
const MaxNameLength = 64

// Load returns the named zone, and false for anything that is not one.
//
// "Local" and the empty string are refused even though LoadLocation accepts
// them: they name the server's zone, which is exactly what a client sending
// its own is trying to get away from.
func Load(name string) (*time.Location, bool) {
	if name == "" || name == "Local" || len(name) > MaxNameLength || !namePattern.MatchString(name) {
		return nil, false
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		return nil, false
	}
	return loc, true
}

// StartOfDay is midnight at the start of t's day in loc.
//
// Built from the date rather than by truncating, because a day is not always
// 24 hours long: on a clock change, midnight is 23 or 25 hours before the next.
func StartOfDay(t time.Time, loc *time.Location) time.Time {
	local := t.In(loc)
	return time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, loc)
}
