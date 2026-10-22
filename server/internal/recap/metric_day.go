package recap

import (
	"net/http"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// Per-person, per-metric, per-day amounts from outside the timeline (#411).
//
//	PUT /api/peard/metric/day  { pair, metric, day, amount, source }  -> { ok, … }
//
// A moment is one event with one amount; a health total is the member's whole
// day so far. The device upserts one row per (pair, user, metric, day), so
// syncing twice is idempotent and the feed sums the final figure once. The user
// comes from the session, never the body, so a caller can only write their own.
//
// Additive: posts are untouched. A reader prefers this row for the day and
// ignores that member's posts for the same metric and day, so manual logging
// and a synced total cannot count twice.

const maxMetricDayAmount = 1_000_000

const metricDayLayout = "2006-01-02"

func registerMetricDay(se *core.ServeEvent) {
	se.Router.PUT("/api/peard/metric/day", metricDayHandler(se.App)).Bind(apis.RequireAuth())
}

func metricDayHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			Pair   string `json:"pair" form:"pair"`
			Metric string `json:"metric" form:"metric"`
			Day    string `json:"day" form:"day"`
			Amount int    `json:"amount" form:"amount"`
			Source string `json:"source" form:"source"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}
		pairID := strings.TrimSpace(body.Pair)
		metric := strings.TrimSpace(body.Metric)
		day := strings.TrimSpace(body.Day)
		source := strings.TrimSpace(body.Source)
		if source == "" {
			source = "health"
		}
		if pairID == "" {
			return e.BadRequestError("pair is required", nil)
		}
		if metric == "" || len(metric) > 40 {
			return e.BadRequestError("metric is required and must be at most 40 characters", nil)
		}
		if _, err := time.Parse(metricDayLayout, day); err != nil {
			return e.BadRequestError("day must be a date, YYYY-MM-DD", nil)
		}
		if len(source) > 20 {
			return e.BadRequestError("source must be at most 20 characters", nil)
		}
		if msg := checkMetricDay(body.Amount); msg != "" {
			return e.BadRequestError(msg, nil)
		}

		mem, err := app.FindFirstRecordByFilter("pair_members",
			"pair = {:pair} && user = {:user}",
			dbx.Params{"pair": pairID, "user": e.Auth.Id})
		if err != nil || mem == nil {
			return e.ForbiddenError("you are not a member of that connection", nil)
		}

		rec, err := app.FindFirstRecordByFilter("metric_days",
			"pair = {:pair} && user = {:user} && metric = {:metric} && day = {:day}",
			dbx.Params{"pair": pairID, "user": e.Auth.Id, "metric": metric, "day": day})
		if err != nil || rec == nil {
			col, cerr := app.FindCollectionByNameOrId("metric_days")
			if cerr != nil {
				return e.InternalServerError("metric_days collection missing", cerr)
			}
			rec = core.NewRecord(col)
			rec.Set("pair", pairID)
			rec.Set("user", e.Auth.Id)
			rec.Set("metric", metric)
			rec.Set("day", day)
		}
		rec.Set("amount", body.Amount)
		rec.Set("source", source)
		if err := app.Save(rec); err != nil {
			return e.InternalServerError("failed to save the day", err)
		}
		return e.JSON(http.StatusOK, map[string]any{
			"ok": true, "metric": metric, "day": day, "amount": body.Amount, "source": source,
		})
	}
}

// checkMetricDay explains why an amount cannot be stored, or returns "".
func checkMetricDay(amount int) string {
	if amount < 0 {
		return "an amount cannot be negative"
	}
	if amount > maxMetricDayAmount {
		return "an amount is too large"
	}
	return ""
}
