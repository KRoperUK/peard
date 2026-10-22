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

// rawDayQuery lists every moment's UTC timestamp within the horizon, newest
// first, so each can be bucketed into its own local day in Go using the IANA
// zone — which knows that day's actual offset (#344). The fixed-offset SQL
// bucketing in dayQuery lands pre-DST days an hour off their true boundary.
const rawDayQuery = `
SELECT happened_at AS day
FROM posts
WHERE pair = {:pair} AND happened_at >= {:since}
ORDER BY happened_at DESC`

// metricRowQuery lists every amount-bearing event of one metric within the
// horizon, with its author, so the amounts can be bucketed into local days in Go
// with IANA-correct boundaries (#344) and summed per member (#391, #411).
const metricRowQuery = `
SELECT happened_at AS day, author AS author, COALESCE(amount, 0) AS amount
FROM posts
WHERE pair = {:pair} AND type = 'event' AND event_kind = {:metric} AND happened_at >= {:since}
ORDER BY happened_at DESC`

// personalMetricRowQuery is metricRowQuery for one author (#353).
const personalMetricRowQuery = `
SELECT happened_at AS day, author AS author, COALESCE(amount, 0) AS amount
FROM posts
WHERE pair = {:pair} AND author = {:user} AND type = 'event' AND event_kind = {:metric} AND happened_at >= {:since}
ORDER BY happened_at DESC`

// metricDayRowQuery lists externally-reported per-day totals (Apple Health,
// #411), already keyed by the member's own local day. A stored day supersedes
// that member's posts for the same metric and day.
const metricDayRowQuery = `
SELECT day AS day, user AS user, COALESCE(amount, 0) AS amount
FROM metric_days
WHERE pair = {:pair} AND metric = {:metric} AND day >= {:since_day}
ORDER BY day DESC`

// personalMetricDayRowQuery is metricDayRowQuery for one member.
const personalMetricDayRowQuery = `
SELECT day AS day, user AS user, COALESCE(amount, 0) AS amount
FROM metric_days
WHERE pair = {:pair} AND user = {:user} AND metric = {:metric} AND day >= {:since_day}
ORDER BY day DESC`

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
		registerMetricTarget(se)
		registerMetricDay(se)
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

// metricAmountRow is one event's timestamp, author and amount, for IANA
// day-bucketing and per-member precedence (#344, #391, #411).
type metricAmountRow struct {
	Day    string `db:"day"`
	Author string `db:"author"`
	Amount int    `db:"amount"`
}

// metricDayAmountRow is one member's externally-reported total for one metric
// on one local day (#411).
type metricDayAmountRow struct {
	Day    string `db:"day"`
	User   string `db:"user"`
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
		// The clock the caller's days are bucketed in: the offset they sent, or
		// their stored zone. A streak is a sequence of days, so it has to agree
		// with the day the caller thinks it is.
		streakLoc := metricStreakZone(e, loc)
		waterCurrent, waterBest := waterStreaks(app, pairID, streakLoc, streakTarget(targets, waterTarget(e)))
		mineCurrent, mineBest := personalMetricStreaks(app, pairID, e.Auth.Id, "water", streakLoc,
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
			// A streak for every other tracked metric (#391): steps, exercise,
			// and any kind a connection gave itself. Water keeps its own fields
			// above; this list never repeats it.
			"metric_streaks": trackedMetricStreaks(app, pairID, e.Auth.Id, streakLoc),
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

// ConnectionStreak is the connection's current and best "any moment" day
// streak, in the given zone — the same figure the recap shows and the
// "streak at risk" reminder (#361) is about. Exported so the widget feed can
// carry it to the watch's streak complication (#378) without the streak SQL
// drifting into a second copy. The zone is the caller's; the shift it derives
// from it is only used on the UTC fast path, so a named zone takes the
// zone-aware day bucketing like the recap does.
func ConnectionStreak(app core.App, pairID string, loc *time.Location) (current, best int) {
	if loc == nil {
		loc = time.UTC
	}
	_, offset := time.Now().In(loc).Zone()
	minutes := offset / 60
	var shift string
	if minutes >= 0 {
		shift = "+" + strconv.Itoa(minutes) + " minutes"
	} else {
		shift = strconv.Itoa(minutes) + " minutes"
	}
	return streaks(app, pairID, shift, loc)
}

// waterStreaks is metricStreaks for the hero: how many days in a row the
// connection's combined total reached `target` millilitres, and the longest
// such run (#323).
//
// The same rule as streaks, so the same liveness: the run reaches back from the
// most recent day that met the target, and is live only if that day is today or
// yesterday. A day that has not reached the target *yet* does not break it.
//
// No target is no streak, not a vacuously true one: with a target of zero every
// day would qualify.
func waterStreaks(app core.App, pairID string, loc *time.Location, target int) (current, best int) {
	return metricStreaks(app, pairID, "water", loc, target)
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

// metricStreaks is a streak for any tracked metric (#391): how many days in a
// row the connection's combined amount reached `target`, and the longest run.
//
// The same rule as the water streak it generalises, so the same liveness: the
// run reaches back from the most recent day that met the target, and is live
// only if that day is today or yesterday. A day that has not reached the target
// *yet* does not break it. No target is no streak, not a vacuously true one.
func metricStreaks(app core.App, pairID, metric string, loc *time.Location, target int) (current, best int) {
	return metricStreaksFor(app, pairID, "", metric, loc, target)
}

// personalMetricStreaks is metricStreaks for one person: how many days in a row
// that member's *own* amount reached `target` (#353).
//
// The same rule and liveness as the connection streak — the run reaches back
// from the most recent day the member met their goal, and is live only if that
// day is today or yesterday. A day not yet at the target does not break it, so
// a nudge at nine in the evening is about a streak still savable, not a lost one.
func personalMetricStreaks(app core.App, pairID, userID, metric string, loc *time.Location, target int) (current, best int) {
	if userID == "" {
		return 0, 0
	}
	return metricStreaksFor(app, pairID, userID, metric, loc, target)
}

// metricStreaksFor reads the qualifying days for one metric, for the whole
// connection or one member, and then the runs of consecutive days among them.
func metricStreaksFor(app core.App, pairID, userID, metric string, loc *time.Location, target int) (current, best int) {
	if target <= 0 {
		return 0, 0
	}
	if loc == nil {
		loc = time.UTC
	}
	since := time.Now().AddDate(0, 0, -streakHorizonDays).UTC().Format(pocketBaseLayout)
	totals := metricDayTotals(app, pairID, userID, metric, since, loc)

	days := make([]time.Time, 0, len(totals))
	for key, total := range totals {
		if total < target {
			continue
		}
		day, err := time.Parse("2006-01-02", key)
		if err != nil {
			continue
		}
		days = append(days, day)
	}
	sort.Slice(days, func(a, b int) bool { return days[a].After(days[b]) })
	return runsFromDays(days, nowInZone(loc))
}

// metricDayTotals sums one metric by local day. With a userID it is that
// member's own days; without one it is the connection's combined days.
//
// Bucketing happens in Go from each event's IANA-aware local day, matching the
// zone-aware path the water streak already used, so a clock change cannot
// misplace an entry logged near midnight (#344).
func metricDayTotals(app core.App, pairID, userID, metric, since string, loc *time.Location) map[string]int {
	query := metricRowQuery
	params := dbx.Params{"pair": pairID, "metric": metric, "since": since}
	if userID != "" {
		query = personalMetricRowQuery
		params["user"] = userID
	}

	var rows []metricAmountRow
	if err := app.DB().NewQuery(query).Bind(params).All(&rows); err != nil {
		return nil
	}

	byMemberDay := map[string]map[string]int{}
	for _, r := range rows {
		day, ok := localDay(r.Day, loc)
		if !ok {
			continue
		}
		key := day.Format(metricDayLayout)
		if byMemberDay[r.Author] == nil {
			byMemberDay[r.Author] = map[string]int{}
		}
		byMemberDay[r.Author][key] += r.Amount
	}

	// A stored day is the member's whole day, not an increment (#411). It
	// replaces their posts for that day, so a connection that also logs a metric
	// by hand cannot count the same steps twice. An explicit zero still wins:
	// the source said the member did none.
	storedParams := dbx.Params{
		"pair":      pairID,
		"metric":    metric,
		"since_day": time.Now().AddDate(0, 0, -streakHorizonDays).In(loc).Format(metricDayLayout),
	}
	storedQuery := metricDayRowQuery
	if userID != "" {
		storedQuery = personalMetricDayRowQuery
		storedParams["user"] = userID
	}
	var stored []metricDayAmountRow
	if err := app.DB().NewQuery(storedQuery).Bind(storedParams).All(&stored); err == nil {
		for _, r := range stored {
			if _, err := time.Parse(metricDayLayout, r.Day); err != nil {
				continue
			}
			if byMemberDay[r.User] == nil {
				byMemberDay[r.User] = map[string]int{}
			}
			byMemberDay[r.User][r.Day] = r.Amount
		}
	}

	totals := make(map[string]int, len(byMemberDay))
	for _, days := range byMemberDay {
		for key, amount := range days {
			totals[key] += amount
		}
	}
	return totals
}

// metricStreak is one tracked metric's streak figures in the recap (#391).
// Water is not listed here: it keeps `water_streak` and `water_streak_mine`.
type metricStreak struct {
	Metric   string        `json:"metric"`
	Current  int           `json:"current"`
	Best     int           `json:"best"`
	Goal     int           `json:"goal"`
	MineGoal int           `json:"mine_goal"`
	Mine     streakFigures `json:"mine"`
}

type streakFigures struct {
	Current int `json:"current"`
	Best    int `json:"best"`
}

// metricDefaultGoal is the built-in daily goal for a metric, mirroring the
// client's MetricCatalogue and the widget feed's builtinMetrics.
func metricDefaultGoal(metric string) int {
	switch metric {
	case "water":
		return defaultWaterTarget
	case "steps":
		return 10000
	case "exercise":
		return 30
	default:
		// A connection's own metric has no built-in goal, so a member who
		// stored none contributes the smallest meaningful one rather than zero
		// (which would make the day vacuously qualify).
		return 1
	}
}

// trackedMetricStreaks reports a streak for every non-water metric the
// connection tracks (#391): one entry per metric that any member has given a
// goal to. The connection's target is the sum of its members' goals, the same
// shape water's targets use; a member without a goal contributes the built-in.
func trackedMetricStreaks(app core.App, pairID, userID string, loc *time.Location) []metricStreak {
	rows, err := app.FindRecordsByFilter("metric_targets",
		"pair = {:pair}", "metric", 0, 0, dbx.Params{"pair": pairID})
	if err != nil || len(rows) == 0 {
		return []metricStreak{}
	}

	goals := map[string]map[string]int{}
	order := []string{}
	for _, row := range rows {
		metric := strings.TrimSpace(row.GetString("metric"))
		goal := row.GetInt("goal")
		if metric == "" || metric == "water" || goal <= 0 {
			continue
		}
		if goals[metric] == nil {
			goals[metric] = map[string]int{}
			order = append(order, metric)
		}
		goals[metric][row.GetString("user")] = goal
	}
	if len(order) == 0 {
		return []metricStreak{}
	}
	sort.Strings(order)

	members, err := app.FindRecordsByFilter("pair_members",
		"pair = {:pair}", "", 0, 0, dbx.Params{"pair": pairID})
	if err != nil {
		return []metricStreak{}
	}

	out := make([]metricStreak, 0, len(order))
	for _, metric := range order {
		fallback := metricDefaultGoal(metric)
		goal := 0
		for _, m := range members {
			if stored := goals[metric][m.GetString("user")]; stored > 0 {
				goal += stored
			} else {
				goal += fallback
			}
		}
		mineGoal := goals[metric][userID]
		if mineGoal <= 0 {
			mineGoal = fallback
		}

		current, best := metricStreaks(app, pairID, metric, loc, goal)
		mineCurrent, mineBest := personalMetricStreaks(app, pairID, userID, metric, loc, mineGoal)
		out = append(out, metricStreak{
			Metric:   metric,
			Current:  current,
			Best:     best,
			Goal:     goal,
			MineGoal: mineGoal,
			Mine:     streakFigures{Current: mineCurrent, Best: mineBest},
		})
	}
	return out
}

// metricStreakZone is the clock metric days are bucketed in: the fixed offset
// the caller sent (clamped like shiftFor), else their stored zone (#344).
func metricStreakZone(e *core.RequestEvent, loc *time.Location) *time.Location {
	raw := strings.TrimSpace(e.Request.URL.Query().Get("tz"))
	if raw == "" {
		return loc
	}
	minutes, err := strconv.Atoi(raw)
	if err != nil {
		return loc
	}
	if minutes > 14*60 {
		minutes = 14 * 60
	}
	if minutes < -14*60 {
		minutes = -14 * 60
	}
	return time.FixedZone("caller", minutes*60)
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
