// Package tallies counts a connection's moments server-side.
//
//	GET /api/peard/tallies?pair=X[&day=…&week=…&month=…]  -> see response below
//
// Why this exists: the app used to fetch every `event` post of a connection
// (`perPage=500`, sorted `-created`) and count them on the device, on every
// single tap. Two things were wrong with that. Past 500 event posts the all-time
// tally silently undercounted — a group of 12 logging beer, loo and coffee gets
// there in weeks — and each tap moved up to 500 records over the wire to derive
// eight integers.
//
// Here it is one `GROUP BY` over an indexed column, so the response is a few
// hundred bytes and stays correct however long a connection lives.
//
// Window boundaries are supplied by the caller. The app counts against local
// midnight and a Monday-start week (`Calendar.peardTally`), and the server has no
// business guessing the device's time zone: a phone in Sydney talking to a server
// in London would otherwise disagree with itself about what "today" means. When
// the parameters are absent the server falls back to its own local boundaries, so
// a caller that does not know about them still gets sensible numbers.
package tallies

import (
	"net/http"
	"strings"
	"time"

	"peard/internal/moments"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// pocketBaseLayout is how PocketBase stores timestamps, and therefore how a
// boundary has to be written for a string comparison against `created` to work.
const pocketBaseLayout = "2006-01-02 15:04:05.000Z"

// maxKinds bounds the per-kind breakdown. A connection's catalogue is capped
// well below this by moment_kinds, so it only guards against a pathological
// history of hand-written kinds.
const maxKinds = 200

// tallyQuery counts a connection's event posts in one pass.
//
// Written out rather than assembled with dbx's query builder: the builder treats
// each Select argument as a column name and quotes it, so a CASE expression
// arrives at SQLite as `"CASE WHEN author = ? THEN 1 ELSE 0 END"` and fails with
// "no such column".
//
// `mine` splits the rows by authorship in the GROUP BY, so one query yields both
// sides of the home screen's two tally rows. The three window columns are counted
// independently, so a week straddling a month boundary cannot inflate the month —
// matching TallyPeriods.compute on the client.
const tallyQuery = `
SELECT
    event_kind                                                  AS event_kind,
    CASE WHEN author = {:user} THEN 1 ELSE 0 END                AS mine,
    SUM(CASE WHEN created >= {:day}   THEN 1 ELSE 0 END)         AS day_count,
    SUM(CASE WHEN created >= {:week}  THEN 1 ELSE 0 END)         AS week_count,
    SUM(CASE WHEN created >= {:month} THEN 1 ELSE 0 END)         AS month_count,
    COUNT(*)                                                    AS all_count
FROM posts
WHERE pair = {:pair} AND type = 'event'
GROUP BY event_kind, mine
LIMIT {:limit}`

// Register binds the tallies route.
func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.GET("/api/peard/tallies", handler(app)).Bind(apis.RequireAuth())
		return se.Next()
	})
}

// counts is one set of window totals.
type counts struct {
	Day   int `json:"day"`
	Week  int `json:"week"`
	Month int `json:"month"`
	All   int `json:"all"`
}

// row is one output of the aggregate query: a kind, whose it is, and the four
// window counts for that combination.
type row struct {
	EventKind string `db:"event_kind"`
	Mine      int    `db:"mine"`
	Day       int    `db:"day_count"`
	Week      int    `db:"week_count"`
	Month     int    `db:"month_count"`
	All       int    `db:"all_count"`
}

func handler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		pairID := strings.TrimSpace(e.Request.URL.Query().Get("pair"))
		if pairID == "" {
			return e.BadRequestError("pair is required", nil)
		}
		// Membership is the authorisation: the posts ListRule would have done
		// this implicitly, but this route reads through the database directly.
		member, err := app.FindFirstRecordByFilter("pair_members",
			"pair = {:pair} && user = {:user}",
			dbx.Params{"pair": pairID, "user": e.Auth.Id})
		if err != nil || member == nil {
			return e.ForbiddenError("you are not a member of that connection", nil)
		}

		day, week, month := windows(e)

		var rows []row
		err = app.DB().
			NewQuery(tallyQuery).
			Bind(dbx.Params{
				"pair":  pairID,
				"user":  e.Auth.Id,
				"day":   day,
				"week":  week,
				"month": month,
				"limit": maxKinds * 2,
			}).
			All(&rows)
		if err != nil {
			return e.InternalServerError("could not count moments", err)
		}

		var mineTotal, othersTotal counts
		perKindMine := map[string]counts{}
		perKindOthers := map[string]counts{}
		order := make([]string, 0, len(rows))
		seen := map[string]bool{}

		for _, r := range rows {
			kind := strings.TrimSpace(r.EventKind)
			if kind == "" {
				// A post with no kind still counts towards the totals — it was
				// somebody's moment — but there is nothing to label it with.
				addTo(bucket(r.Mine, &mineTotal, &othersTotal), r)
				continue
			}
			if !seen[kind] {
				seen[kind] = true
				order = append(order, kind)
			}
			if r.Mine == 1 {
				perKindMine[kind] = added(perKindMine[kind], r)
				addTo(&mineTotal, r)
			} else {
				perKindOthers[kind] = added(perKindOthers[kind], r)
				addTo(&othersTotal, r)
			}
		}

		descriptors := moments.ResolveAll(app, pairID, order)
		kinds := make([]map[string]any, 0, len(order))
		for _, kind := range order {
			d := descriptors[kind]
			mine := perKindMine[kind]
			others := perKindOthers[kind]
			kinds = append(kinds, map[string]any{
				"kind":   kind,
				"emoji":  d.Emoji,
				"label":  d.Label,
				"mine":   mine,
				"others": others,
				"total":  mine.All + others.All,
			})
		}

		return e.JSON(http.StatusOK, map[string]any{
			"pair":   pairID,
			"mine":   mineTotal,
			"others": othersTotal,
			"kinds":  kinds,
		})
	}
}

// windows resolves the three boundaries, preferring the caller's.
func windows(e *core.RequestEvent) (day, week, month string) {
	query := e.Request.URL.Query()
	now := time.Now()

	day = boundary(query.Get("day"), startOfDay(now))
	week = boundary(query.Get("week"), startOfWeek(now))
	month = boundary(query.Get("month"), startOfMonth(now))
	return day, week, month
}

// boundary parses an RFC 3339 instant into PocketBase's storage layout, falling
// back to the server-side default when it is missing or unparseable.
func boundary(supplied string, fallback time.Time) string {
	supplied = strings.TrimSpace(supplied)
	if supplied != "" {
		if parsed, err := time.Parse(time.RFC3339, supplied); err == nil {
			return parsed.UTC().Format(pocketBaseLayout)
		}
	}
	return fallback.UTC().Format(pocketBaseLayout)
}

func startOfDay(now time.Time) time.Time {
	return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
}

// startOfWeek pins the week to Monday, matching the client's Calendar.
func startOfWeek(now time.Time) time.Time {
	day := startOfDay(now)
	offset := (int(day.Weekday()) + 6) % 7 // Monday = 0
	return day.AddDate(0, 0, -offset)
}

func startOfMonth(now time.Time) time.Time {
	return time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, now.Location())
}

func bucket(mine int, mineTotal, othersTotal *counts) *counts {
	if mine == 1 {
		return mineTotal
	}
	return othersTotal
}

func addTo(target *counts, r row) {
	target.Day += r.Day
	target.Week += r.Week
	target.Month += r.Month
	target.All += r.All
}

func added(base counts, r row) counts {
	addTo(&base, r)
	return base
}
