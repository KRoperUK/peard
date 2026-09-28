package push

import (
	"sort"
	"strconv"
	"strings"
	"time"

	"peard/internal/moments"
	"peard/internal/zone"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/payload"
)

// The weekly recap goes out at 18:00 on Sunday wherever each device is.
//
// It used to be one run at 18:00 UTC, which is Sunday evening in London for
// half the year and four on Monday morning in Sydney. Now the job runs every
// hour and each run sends to the devices whose own clock reads Sunday in the
// 18:00 hour, using the zone the app stores on its device row — UTC for a
// device that has not said. Hourly, on the hour, so a zone offset by half an
// hour or more gets it at 18:30 or 18:45 rather than early.
//
// No opt-out beyond muting the connection yet — the first thing to revisit if
// somebody asks to turn it off.
const (
	weeklyRecapCron = "0 * * * *"
	recapWeekday    = time.Sunday
	recapHour       = 18
)

// maxPairsPerRecap and maxRecapPosts bound one run to what a personal-scale
// deployment actually has, the same way the rest of this package does — not
// paginated, because there is no fleet of connections to page through.
const (
	maxPairsPerRecap = 10000
	maxRecapPosts    = 2000
	// How many kinds to name in one push before falling back to "and more".
	maxRecapKinds = 4
)

func registerWeeklyRecap(app core.App) {
	app.Cron().MustAdd("weeklyRecap", weeklyRecapCron, func() {
		sendWeeklyRecaps(app)
	})
}

func sendWeeklyRecaps(app core.App) {
	sendWeeklyRecapsAt(app, time.Now())
}

// sendWeeklyRecapsAt sends the recap to every device whose Sunday evening it is
// at now: one push per connection that had at least one moment logged since
// that device's Monday, to every member — a group summary of what the
// connection did, not a per-member "your week" ledger.
func sendWeeklyRecapsAt(app core.App, now time.Time) {
	if n == nil {
		return
	}

	// Most hours of the week are nobody's Sunday evening, so the zones are
	// checked before any connection is: for the other hours a run is one
	// small query and nothing more.
	due := dueZones(app, now)
	if len(due) == 0 {
		return
	}

	pairs, err := app.FindRecordsByFilter("pairs", "", "", maxPairsPerRecap, 0, dbx.Params{})
	if err != nil {
		app.Logger().Error("push: weekly recap could not list pairs", "error", err)
		return
	}

	for _, pair := range pairs {
		sendRecapFor(app, pair, now, due)
	}
}

// recapDue reports whether now falls in the recap's hour — Sunday, 18:00 to
// 18:59 — on the clock in loc.
//
// Asked of the local clock rather than worked out as a UTC hour, so a clock
// change needs no special case: whatever the offset that Sunday, 18:00 happens
// exactly once.
func recapDue(now time.Time, loc *time.Location) bool {
	local := now.In(loc)
	return local.Weekday() == recapWeekday && local.Hour() == recapHour
}

// deviceZone is the zone stored on a device row, or UTC when there is none or
// it is not a zone — a device registered by a build that predates the field
// gets the recap when every device used to.
func deviceZone(stored string) *time.Location {
	if loc, ok := zone.Load(stored); ok {
		return loc
	}
	return time.UTC
}

// dueZones is the set of stored time_zone values, "" included, whose devices
// are due a recap at now.
func dueZones(app core.App, now time.Time) map[string]bool {
	var rows []struct {
		TimeZone string `db:"time_zone"`
	}
	if err := app.DB().Select("time_zone").Distinct(true).From("devices").All(&rows); err != nil {
		app.Logger().Error("push: weekly recap could not read device zones", "error", err)
		return nil
	}
	due := map[string]bool{}
	for _, row := range rows {
		if recapDue(now, deviceZone(row.TimeZone)) {
			due[row.TimeZone] = true
		}
	}
	return due
}

func sendRecapFor(app core.App, pair *core.Record, now time.Time, due map[string]bool) {
	title := "This week"
	if name := pair.GetString("name"); name != "" {
		title = "This week in " + name
	}

	// Devices in different zones have different Mondays, so the body is worked
	// out once per week start this connection is asked about.
	bodies := map[time.Time]string{}
	bodyFor := func(weekStart time.Time) string {
		if body, ok := bodies[weekStart]; ok {
			return body
		}
		body := ""
		posts, err := app.FindRecordsByFilter("posts",
			"pair = {:pair} && type = 'event' && happened_at >= {:week}",
			"", maxRecapPosts, 0,
			dbx.Params{"pair": pair.Id, "week": weekStart.UTC().Format("2006-01-02 15:04:05.000Z")})
		// Nothing happened, or the query failed — either way, a silent
		// connection gets no recap rather than an empty or broken one.
		if err == nil && len(posts) > 0 {
			body = recapBody(app, pair.Id, posts)
		}
		bodies[weekStart] = body
		return body
	}

	// Muted members are left out, as they are for moment pushes: the recap is
	// that connection making a noise, which is what muting it asked to stop.
	members, err := app.FindRecordsByFilter("pair_members",
		"pair = {:pair} && muted != true", "", maxFanOut, 0, dbx.Params{"pair": pair.Id})
	if err != nil {
		return
	}

	threadID := "pair-" + pair.Id
	for _, member := range members {
		userID := member.GetString("user")
		devices, err := app.FindRecordsByFilter("devices",
			"user = {:user}", "", 20, 0, dbx.Params{"user": userID})
		if err != nil {
			continue
		}
		for _, d := range devices {
			t := d.GetString("push_token")
			stored := d.GetString("time_zone")
			if t == "" || !due[stored] {
				continue
			}
			body := bodyFor(startOfWeek(now.In(deviceZone(stored))))
			if body == "" {
				continue
			}
			p := payload.NewPayload().
				AlertTitle(title).AlertBody(body).
				Sound("default").
				ThreadID(threadID).
				Custom("pair_id", pair.Id)
			if n.send(t, p, apns2.PushTypeAlert, apns2.PriorityLow, "recap:"+pair.Id) {
				forgetDevice(app, d)
			}
		}
	}
}

// recapBody turns this week's posts into "4 🍺, 2 ☕, 1 💩", most frequent
// first, matching the tallies row style used elsewhere.
func recapBody(app core.App, pairID string, posts []*core.Record) string {
	counts := map[string]int{}
	order := []string{}
	for _, post := range posts {
		kind := post.GetString("event_kind")
		if kind == "" {
			continue
		}
		if _, seen := counts[kind]; !seen {
			order = append(order, kind)
		}
		counts[kind]++
	}
	if len(order) == 0 {
		return ""
	}

	sort.SliceStable(order, func(i, j int) bool { return counts[order[i]] > counts[order[j]] })
	if len(order) > maxRecapKinds {
		order = order[:maxRecapKinds]
	}

	descriptors := moments.ResolveAll(app, pairID, order)
	parts := make([]string, 0, len(order))
	for _, kind := range order {
		d := descriptors[kind]
		parts = append(parts, d.Emoji+" "+strconv.Itoa(counts[kind]))
	}
	return strings.Join(parts, ", ")
}

// startOfWeek pins the week to Monday in now's location, matching
// internal/tallies —
// duplicated rather than imported, the same call the rest of this codebase
// already makes for small time-window helpers (see widget.startOfToday).
func startOfWeek(now time.Time) time.Time {
	day := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	offset := (int(day.Weekday()) + 6) % 7 // Monday = 0
	return day.AddDate(0, 0, -offset)
}
