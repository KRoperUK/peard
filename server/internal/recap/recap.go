// Package recap summarises a connection's recent moments, and how long it has
// kept going.
//
//	GET /api/peard/recap?pair=X[&from=…&tz=±minutes]  -> see response below
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

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// How PocketBase stores timestamps, and therefore how a boundary has to be
// written for a string comparison against `created` to work.
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
// back rather than every post. `replace(created,'Z',”)` is load-bearing:
// PocketBase stores `2026-08-01 21:41:47.123Z`, and SQLite's date functions
// return null for the trailing Z rather than erroring — which would have made
// every streak silently zero.
const dayQuery = `
SELECT DISTINCT substr(datetime(replace(created, 'Z', ''), {:shift}), 1, 10) AS day
FROM posts
WHERE pair = {:pair} AND created >= {:since}
ORDER BY day DESC`

// windowQuery counts the recap window in one pass, split by authorship.
const windowQuery = `
SELECT
    event_kind                                   AS event_kind,
    CASE WHEN author = {:user} THEN 1 ELSE 0 END AS mine,
    COUNT(*)                                     AS total
FROM posts
WHERE pair = {:pair} AND type = 'event' AND created >= {:from}
GROUP BY event_kind, mine`

// busiestQuery finds the local day in the window with the most moments.
const busiestQuery = `
SELECT
    substr(datetime(replace(created, 'Z', ''), {:shift}), 1, 10) AS day,
    COUNT(*)                                                     AS total
FROM posts
WHERE pair = {:pair} AND created >= {:from}
GROUP BY day
ORDER BY total DESC, day DESC
LIMIT 1`

func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.GET("/api/peard/recap", handler(app)).Bind(apis.RequireAuth())
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

		shift := shiftFor(e)
		from := windowStart(e)

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

		current, best := streaks(app, pairID, shift)

		res := map[string]any{
			"pair":   pairID,
			"from":   from,
			"total":  mine + others,
			"mine":   mine,
			"others": others,
			"kinds":  summary,
			"streak": map[string]any{"current": current, "best": best},
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
func streaks(app core.App, pairID, shift string) (current, best int) {
	since := time.Now().AddDate(0, 0, -streakHorizonDays).UTC().Format(pocketBaseLayout)

	var rows []dayRow
	if err := app.DB().NewQuery(dayQuery).Bind(dbx.Params{
		"pair": pairID, "since": since, "shift": shift,
	}).All(&rows); err != nil {
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
	if len(days) == 0 {
		return 0, 0
	}

	// The caller's today, derived from the same shift the days were bucketed
	// with, so "is the newest day today or yesterday" is asked in one clock.
	today := shiftedNow(shift)

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

	// The current run is only the leading one, and only if it reaches today or
	// yesterday.
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

// shiftFor turns the caller's UTC offset into a SQLite datetime modifier.
//
// Clamped to a real range so a malformed or hostile value cannot make SQLite
// walk somewhere absurd; ±14 hours covers every zone in use, including the ones
// offset by 45 minutes.
func shiftFor(e *core.RequestEvent) string {
	minutes, err := strconv.Atoi(strings.TrimSpace(e.Request.URL.Query().Get("tz")))
	if err != nil {
		_, offset := time.Now().Zone()
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
func windowStart(e *core.RequestEvent) string {
	supplied := strings.TrimSpace(e.Request.URL.Query().Get("from"))
	if supplied != "" {
		if parsed, err := time.Parse(time.RFC3339, supplied); err == nil {
			return parsed.UTC().Format(pocketBaseLayout)
		}
	}
	now := time.Now()
	start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	return start.AddDate(0, 0, -(recapDays - 1)).UTC().Format(pocketBaseLayout)
}
