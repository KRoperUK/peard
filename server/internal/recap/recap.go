// Package recap summarises a connection's recent moments, and how long it has
// kept going.
//
//	GET /api/peard/recap?pair=X[&from=…&tz=±minutes]  -> see response below
//	POST /api/peard/water/target  { pair, minimum, recommended }  -> see target.go
//
// Why this exists: the app could say how many moments there had ever been and
// how many today, and nothing in between. Neither is a story. "Fourteen coffees
// this week, nine of them yours, and you have both logged something five days
// running" is — and it is the only thing here that gives somebody a reason to
// open the app when nobody has just sent them anything.
//
// A streak counts days on which *anybody* in the connection logged a moment,
// rather than days on which everybody did. Requiring everybody makes one busy
// Tuesday everyone's fault, which is the opposite of the point; the connection
// keeping going is the shared thing worth counting.
//
// Day boundaries come from the caller's clock, like the tallies route's windows
// and for the same reason: a phone in Sydney and a server in London disagree
// about what "today" is, and a streak is nothing but a sequence of days.
package recap

import (
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"peard/internal/moments"
	"peard/internal/zone"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// How PocketBase stores timestamps, and therefore how a boundary has to be
// written for a string comparison against `happened_at` to work.
const pocketBaseLayout = "2006-01-02 15:04:05.000Z"

// How far back a streak is looked for.
//
// Bounded because this is a fixed cost paid on every request, and unbounded
// history would make the oldest connections the slowest. Half a year is far
// longer than any streak anybody will keep, and a streak that really did run
// longer still reports 180 — understating a remarkable run, which is a better
// failure than a slow route.
const streakHorizonDays = 180

// recapDays is the window the summary covers when the caller does not say.
const recapDays = 7

// dayQuery lists the distinct local days a connection logged anything on,
// newest first.
//
// The shift is applied in SQL rather than in Go so only one row per day comes
// back rather than every post. `replace(happened_at,'Z',”)` is load-bearing:
// PocketBase stores `2026-08-01 21:41:47.123Z`, and SQLite's date functions
// return null for the trailing Z rather than erroring — which would have made
// every streak silently zero.
const dayQuery = `
SELECT DISTINCT substr(datetime(replace(happened_at, 'Z', ''), {:shift}), 1, 10) AS day
FROM posts
WHERE pair = {:pair} AND happened_at >= {:since}
ORDER BY day DESC`

// waterDayQuery lists the distinct local days the connection's combined water
// reached the target, newest first (#323).
//
// The same bucketing as dayQuery, deliberately: `replace(happened_at,'Z',”)`
// and the caller's `{:shift}`, so a day means one thing to both streaks. What
// differs is the predicate. A day counts when everything logged that local day
// adds up to the target, whoever logged it; a moment with no amount stores 0 and
// adds nothing. Restricted to `type = 'event'` like the tallies' daily total.
const waterDayQuery = `
SELECT substr(datetime(replace(happened_at, 'Z', ''), {:shift}), 1, 10) AS day
FROM posts
WHERE pair = {:pair} AND type = 'event' AND happened_at >= {:since}
GROUP BY day
HAVING SUM(COALESCE(amount, 0)) >= {:target}
ORDER BY day DESC`

// rawDayQuery lists every moment's UTC timestamp within the horizon, newest
// first, so each can be bucketed into its own local day in Go using the IANA
// zone — which knows that day's actual offset (#344). The fixed-offset SQL
// bucketing in dayQuery lands pre-DST days an hour off their true boundary.
const rawDayQuery = `
SELECT happened_at AS day
FROM posts
WHERE pair = {:pair} AND happened_at >= {:since}
ORDER BY happened_at DESC`

// rawWaterDayQuery is rawDayQuery for water: every event's timestamp and amount,
// so the per-local-day sum (and the >= target test) can be computed in Go with
// IANA-correct day boundaries (#344).
const rawWaterDayQuery = `
SELECT happened_at AS day, COALESCE(amount, 0) AS amount
FROM posts
WHERE pair = {:pair} AND type = 'event' AND happened_at >= {:since}
ORDER BY happened_at DESC`

// personalWaterDayQuery is waterDayQuery for one person: the distinct local days
// that member's *own* water reached their target, newest first (#353).
//
// Where waterDayQuery sums the whole connection against the pair's combined
// goal, this sums one author against their own. The per-person streak is the
// one an "at-risk" reminder can be about — a nudge is to the person who is
// behind, not to the connection.
const personalWaterDayQuery = `
SELECT substr(datetime(replace(happened_at, 'Z', ''), {:shift}), 1, 10) AS day
FROM posts
WHERE pair = {:pair} AND author = {:user} AND type = 'event' AND happened_at >= {:since}
GROUP BY day
HAVING SUM(COALESCE(amount, 0)) >= {:target}
ORDER BY day DESC`

// rawPersonalWaterDayQuery is rawWaterDayQuery for one person: every event's
// timestamp and amount by that author, so the per-local-day sum (and >= target
// test) buckets with IANA-correct day boundaries (#344, #353).
const rawPersonalWaterDayQuery = `
SELECT happened_at AS day, COALESCE(amount, 0) AS amount
FROM posts
WHERE pair = {:pair} AND author = {:user} AND type = 'event' AND happened_at >= {:since}
ORDER BY happened_at DESC`

// defaultWaterTarget is the built-in recommended daily amount in millilitres,
// used for a member who has stored no target when the caller sends none either.
// Mirrors the app's `WaterAmount.defaultRecommended`.
const defaultWaterTarget = 2000

// windowQuery counts the recap window in one pass, split by authorship.
const windowQuery = `
SELECT
    event_kind                                   AS event_kind,
    CASE WHEN author = {:user} THEN 1 ELSE 0 END AS mine,
    COUNT(*)                                     AS total
FROM posts
WHERE pair = {:pair} AND type = 'event' AND happened_at >= {:from}
GROUP BY event_kind, mine`

// busiestQuery finds the local day in the window with the most moments.
const busiestQuery = `
SELECT
    substr(datetime(replace(happened_at, 'Z', ''), {:shift}), 1, 10) AS day,
    COUNT(*)                                                     AS total
FROM posts
WHERE pair = {:pair} AND happened_at >= {:from}
GROUP BY day
ORDER BY total DESC, day DESC
LIMIT 1`

func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.GET("/api/peard/recap", handler(app)).Bind(apis.RequireAuth())
		registerTarget(se)
		return se.Next()
	})
}

type dayRow struct {
	Day string `db:"day"`
}

type kindRow struct {
	EventKind string `db:"event_kind"`
	Mine      int    `db:"mine"`
	Total     int    `db:"total"`
}

type busiestRow struct {
	Day   string `db:"day"`
	Total int    `db:"total"`
}

// waterRawRow is one event's timestamp and amount, for IANA day-bucketing (#344).
type waterRawRow struct {
	Day    string `db:"day"`
	Amount int    `db:"amount"`
}

func handler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		pairID := strings.TrimSpace(e.Request.URL.Query().Get("pair"))
		if pairID == "" {
			return e.BadRequestError("pair is required", nil)
		}
		// Membership is the authorisation: this route reads through the
		// database directly, so the posts ListRule never sees it.
		member, err := app.FindFirstRecordByFilter("pair_members",
			"pair = {:pair} && user = {:user}",
			dbx.Params{"pair": pairID, "user": e.Auth.Id})
		if err != nil || member == nil {
			return e.ForbiddenError("you are not a member of that connection", nil)
		}

		// Only consulted when the caller sends no zone or window of its own.
		loc := zone.ForUser(app, e.Auth.Id)
		shift := shiftFor(e, loc)
		from := windowStart(e, loc)

		var kinds []kindRow
		if err := app.DB().NewQuery(windowQuery).Bind(dbx.Params{
			"pair": pairID, "user": e.Auth.Id, "from": from,
		}).All(&kinds); err != nil {
			return e.InternalServerError("could not summarise moments", err)
		}

		mine, others := 0, 0
		perKind := map[string]int{}
		order := []string{}
		for _, k := range kinds {
			if k.Mine == 1 {
				mine += k.Total
			} else {
				others += k.Total
			}
			kind := strings.TrimSpace(k.EventKind)
			if kind == "" {
				continue
			}
			if perKind[kind] == 0 {
				order = append(order, kind)
			}
			perKind[kind] += k.Total
		}

		// Most-logged first, and alphabetically within a tie so the same week
		// does not reorder itself between two requests.
		sort.SliceStable(order, func(a, b int) bool {
			if perKind[order[a]] != perKind[order[b]] {
				return perKind[order[a]] > perKind[order[b]]
			}
			return order[a] < order[b]
		})
		descriptors := moments.ResolveAll(app, pairID, order)
		summary := make([]map[string]any, 0, len(order))
		for _, kind := range order {
			d := descriptors[kind]
			summary = append(summary, map[string]any{
				"kind":  kind,
				"emoji": d.Emoji,
				"label": d.Label,
				"count": perKind[kind],
			})
		}

		current, best := streaks(app, pairID, shift, loc)
		targets := memberTargets(app, pairID)
		waterCurrent, waterBest := waterStreaks(app, pairID, shift, loc, streakTarget(targets, waterTarget(e)))
		mineCurrent, mineBest := personalWaterStreaks(app, pairID, e.Auth.Id, shift, loc,
			personalTarget(targets, e.Auth.Id, waterTarget(e)))

		res := map[string]any{
			"pair":   pairID,
			"from":   from,
			"total":  mine + others,
			"mine":   mine,
			"others": others,
			"kinds":  summary,
			"streak": map[string]any{"current": current, "best": best},
			// Consecutive days the connection's water reached the target.
			"water_streak": map[string]any{"current": waterCurrent, "best": waterBest},
			// Consecutive days the *caller's own* water reached their own target
			// (#353): the streak an at-risk reminder is about.
			"water_streak_mine": map[string]any{"current": mineCurrent, "best": mineBest},
			// Every member's own daily targets (#335), the caller's included, so
			// both people see each other's goals. Zero means none stored.
			"water_targets": targets,
		}

		var busiest []busiestRow
		if err := app.DB().NewQuery(busiestQuery).Bind(dbx.Params{
			"pair": pairID, "from": from, "shift": shift,
		}).All(&busiest); err == nil && len(busiest) > 0 && busiest[0].Day != "" {
			res["busiest"] = map[string]any{"date": busiest[0].Day, "count": busiest[0].Total}
		}

		return e.JSON(http.StatusOK, res)
	}
}

// streaks returns how many days in a row the connection has logged something,
// and the longest such run within the horizon.
//
// "In a row" ends at yesterday, not at today: a streak is alive until a day
// passes with nothing in it, and a connection that has not logged anything yet
// today at nine in the morning has not broken anything.
func streaks(app core.App, pairID, shift string, loc *time.Location) (current, best int) {
	since := time.Now().AddDate(0, 0, -streakHorizonDays).UTC().Format(pocketBaseLayout)
	if loc != nil && loc != time.UTC {
		days := ianaDays(app, pairID, since, loc)
		return runsFromDays(days, nowInZone(loc))
	}
	return streaksFrom(app, dayQuery, dbx.Params{"pair": pairID, "shift": shift}, shift)
}

// waterStreaks is streaks for water: how many days in a row the connection's
// combined total reached `target` millilitres, and the longest such run.
//
// The same rule as streaks, so the same liveness: the run reaches back from the
// most recent day that met the target, and is live only if that day is today or
// yesterday. A day that has not reached the target *yet* does not break it.
//
// No target is no streak, not a vacuously true one: with a target of zero every
// day would qualify.
func waterStreaks(app core.App, pairID, shift string, loc *time.Location, target int) (current, best int) {
	if target <= 0 {
		return 0, 0
	}
	since := time.Now().AddDate(0, 0, -streakHorizonDays).UTC().Format(pocketBaseLayout)
	if loc != nil && loc != time.UTC {
		days := ianaWaterDays(app, pairID, since, loc, target)
		return runsFromDays(days, nowInZone(loc))
	}
	return streaksFrom(app, waterDayQuery, dbx.Params{"pair": pairID, "shift": shift, "target": target}, shift)
}

// ianaDays returns the distinct local days (newest first) the connection logged
// anything on, each day's boundary taken from the IANA zone so a clock change
// does not misplace a moment (#344).
func ianaDays(app core.App, pairID, since string, loc *time.Location) []time.Time {
	var rows []dayRow
	if err := app.DB().NewQuery(rawDayQuery).Bind(dbx.Params{"pair": pairID, "since": since}).All(&rows); err != nil {
		return nil
	}
	seen := map[string]struct{}{}
	days := make([]time.Time, 0, len(rows))
	for _, r := range rows {
		day, ok := localDay(r.Day, loc)
		if !ok {
			continue
		}
		key := day.Format("2006-01-02")
		if _, dup := seen[key]; dup {
			continue
		}
		seen[key] = struct{}{}
		days = append(days, day)
	}
	return days
}

// ianaWaterDays returns the distinct local days (newest first) on which the
// connection's combined water met the target, bucketed by the IANA zone (#344).
func ianaWaterDays(app core.App, pairID, since string, loc *time.Location, target int) []time.Time {
	var rows []waterRawRow
	if err := app.DB().NewQuery(rawWaterDayQuery).Bind(dbx.Params{"pair": pairID, "since": since}).All(&rows); err != nil {
		return nil
	}
	totals := map[string]int{}
	keys := map[string]time.Time{}
	for _, r := range rows {
		day, ok := localDay(r.Day, loc)
		if !ok {
			continue
		}
		key := day.Format("2006-01-02")
		totals[key] += r.Amount
		keys[key] = day
	}
	days := make([]time.Time, 0, len(totals))
	for key, total := range totals {
		if total >= target {
			days = append(days, keys[key])
		}
	}
	sort.Slice(days, func(a, b int) bool { return days[a].After(days[b]) })
	return days
}

// personalWaterStreaks is waterStreaks for one person: how many days in a row
// that member's *own* water reached `target`, and the longest such run (#353).
//
// The same rule and liveness as the connection streak — the run reaches back
// from the most recent day the member met their goal, and is live only if that
// day is today or yesterday. A day not yet at the target does not break it, so
// a nudge at nine in the evening is about a streak still savable, not a lost one.
//
// No target is no streak, as for the connection: a target of zero would make
// every day vacuously qualify.
func personalWaterStreaks(app core.App, pairID, userID, shift string, loc *time.Location, target int) (current, best int) {
	if target <= 0 {
		return 0, 0
	}
	since := time.Now().AddDate(0, 0, -streakHorizonDays).UTC().Format(pocketBaseLayout)
	if loc != nil && loc != time.UTC {
		days := ianaPersonalWaterDays(app, pairID, userID, since, loc, target)
		return runsFromDays(days, nowInZone(loc))
	}
	return streaksFrom(app, personalWaterDayQuery,
		dbx.Params{"pair": pairID, "user": userID, "shift": shift, "target": target}, shift)
}

// ianaPersonalWaterDays is ianaWaterDays for one person: the distinct local
// days that member's own water met the target, bucketed by the IANA zone (#344,
// #353).
func ianaPersonalWaterDays(app core.App, pairID, userID, since string, loc *time.Location, target int) []time.Time {
	var rows []waterRawRow
	if err := app.DB().NewQuery(rawPersonalWaterDayQuery).
		Bind(dbx.Params{"pair": pairID, "user": userID, "since": since}).All(&rows); err != nil {
		return nil
	}
	totals := map[string]int{}
	keys := map[string]time.Time{}
	for _, r := range rows {
		day, ok := localDay(r.Day, loc)
		if !ok {
			continue
		}
		key := day.Format("2006-01-02")
		totals[key] += r.Amount
		keys[key] = day
	}
	days := make([]time.Time, 0, len(totals))
	for key, total := range totals {
		if total >= target {
			days = append(days, keys[key])
		}
	}
	sort.Slice(days, func(a, b int) bool { return days[a].After(days[b]) })
	return days
}

// localDay parses a PocketBase timestamp and returns the date-only value of the
// local day it falls on in loc, as a UTC-midnight time comparable to the others.
func localDay(raw string, loc *time.Location) (time.Time, bool) {
	raw = strings.TrimSpace(raw)
	t, err := time.Parse(pocketBaseLayout, raw)
	if err != nil {
		// Timestamps without millisecond precision still have to bucket.
		t, err = time.Parse("2006-01-02 15:04:05Z", raw)
		if err != nil {
			return time.Time{}, false
		}
	}
	local := t.In(loc)
	return time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, time.UTC), true
}

// nowInZone is today's date in loc, as a UTC-midnight value to compare against
// the bucketed days.
func nowInZone(loc *time.Location) time.Time {
	now := time.Now().In(loc)
	return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
}

// runsFromDays reads the current and best runs of consecutive days from a
// newest-first list of local days. Shared by the IANA and shift paths so both
// count a streak the same way; `today` is the clock the days were bucketed in.
func runsFromDays(days []time.Time, today time.Time) (current, best int) {
	if len(days) == 0 {
		return 0, 0
	}
	run := 1
	best = 1
	for i := 1; i < len(days); i++ {
		if days[i-1].AddDate(0, 0, -1).Equal(days[i]) {
			run++
		} else {
			run = 1
		}
		if run > best {
			best = run
		}
	}
	gap := int(today.Sub(days[0]).Hours() / 24)
	if gap > 1 {
		return 0, best
	}
	current = 1
	for i := 1; i < len(days); i++ {
		if !days[i-1].AddDate(0, 0, -1).Equal(days[i]) {
			break
		}
		current++
	}
	return current, best
}

// streaksFrom runs a query that lists qualifying local days newest first, and
// reads the current and best runs of consecutive days from them.
func streaksFrom(app core.App, query string, params dbx.Params, shift string) (current, best int) {
	params["since"] = time.Now().AddDate(0, 0, -streakHorizonDays).UTC().Format(pocketBaseLayout)

	var rows []dayRow
	if err := app.DB().NewQuery(query).Bind(params).All(&rows); err != nil {
		return 0, 0
	}

	days := make([]time.Time, 0, len(rows))
	for _, r := range rows {
		parsed, err := time.Parse("2006-01-02", r.Day)
		if err != nil {
			continue
		}
		days = append(days, parsed)
	}

	// The caller's today, derived from the same shift the days were bucketed
	// with, so "is the newest day today or yesterday" is asked in one clock.
	return runsFromDays(days, shiftedNow(shift))
}

// waterTarget reads the recommended daily amount the caller sent in millilitres.
//
// It is the fallback for a member who has stored no target of their own (#335):
// an app that predates per-person targets still sends its device-local one.
// Absent or not a number is the built-in default, because the oldest sent
// nothing. A number that is zero or negative is taken at its word as "no target",
// which waterStreaks answers with zero.
func waterTarget(e *core.RequestEvent) int {
	raw := strings.TrimSpace(e.Request.URL.Query().Get("water_target"))
	if raw == "" {
		return defaultWaterTarget
	}
	target, err := strconv.Atoi(raw)
	if err != nil {
		return defaultWaterTarget
	}
	return target
}

// shiftFor turns the caller's UTC offset into a SQLite datetime modifier.
//
// Clamped to a real range so a malformed or hostile value cannot make SQLite
// walk somewhere absurd; ±14 hours covers every zone in use, including the ones
// offset by 45 minutes.
//
// Without one, the caller's stored zone's current offset (#268), rather than
// the server's.
func shiftFor(e *core.RequestEvent, loc *time.Location) string {
	minutes, err := strconv.Atoi(strings.TrimSpace(e.Request.URL.Query().Get("tz")))
	if err != nil {
		_, offset := time.Now().In(loc).Zone()
		minutes = offset / 60
	}
	if minutes > 14*60 {
		minutes = 14 * 60
	}
	if minutes < -14*60 {
		minutes = -14 * 60
	}
	if minutes >= 0 {
		return "+" + strconv.Itoa(minutes) + " minutes"
	}
	return strconv.Itoa(minutes) + " minutes"
}

// shiftedNow is the current date in the caller's clock, as a date-only value to
// compare against the bucketed days.
func shiftedNow(shift string) time.Time {
	minutes := 0
	trimmed := strings.TrimSuffix(strings.TrimSpace(shift), " minutes")
	if parsed, err := strconv.Atoi(strings.TrimPrefix(trimmed, "+")); err == nil {
		minutes = parsed
	}
	now := time.Now().UTC().Add(time.Duration(minutes) * time.Minute)
	return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
}

// windowStart is the beginning of the summarised period, preferring the
// caller's boundary for the same reason the tallies route does.
func windowStart(e *core.RequestEvent, loc *time.Location) string {
	return windowStartAt(e.Request.URL.Query().Get("from"), time.Now().In(loc))
}

// windowStartAt is windowStart with the clock and zone given, for testing.
// Without a supplied boundary the window starts at midnight in now's zone.
func windowStartAt(from string, now time.Time) string {
	supplied := strings.TrimSpace(from)
	if supplied != "" {
		if parsed, err := time.Parse(time.RFC3339, supplied); err == nil {
			return parsed.UTC().Format(pocketBaseLayout)
		}
	}
	start := zone.StartOfDay(now, now.Location())
	return start.AddDate(0, 0, -(recapDays - 1)).UTC().Format(pocketBaseLayout)
}
