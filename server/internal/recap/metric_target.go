package recap

import (
	"net/http"
	"strings"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// Per-person, per-metric daily targets (#386) — the generalisation of the water
// target route to any trackable metric.
//
//	POST /api/peard/metric/target  { pair, metric, minimum, goal }  -> { ok, metric, minimum, goal }
//
// Each member owns their own target for each metric (water, steps, exercise, a
// connection's own tracked kind), stored in the metric_targets collection.
// Everybody in the connection reads everybody's through that collection's
// ListRule; only the owner writes theirs, and only through this route, which
// upserts exactly the (pair, user, metric) row. The user comes from the session,
// never the body, so a caller can only ever write their own.
//
// Additive: the water columns and /api/peard/water/target are untouched. A
// generalised reader prefers a metric_targets row and falls back to the water
// columns (and then the built-in defaults) for the water metric, so nothing a
// water user has set is lost.

// maxMetricTarget is the largest target any metric may store: the general
// ceiling (steps run to the tens of thousands), well above water's own 5000 ml
// which its route still enforces separately.
const maxMetricTarget = 1_000_000

func registerMetricTarget(se *core.ServeEvent) {
	se.Router.POST("/api/peard/metric/target", metricTargetHandler(se.App)).Bind(apis.RequireAuth())
}

func metricTargetHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			Pair    string `json:"pair" form:"pair"`
			Metric  string `json:"metric" form:"metric"`
			Minimum int    `json:"minimum" form:"minimum"`
			Goal    int    `json:"goal" form:"goal"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}
		pairID := strings.TrimSpace(body.Pair)
		metric := strings.TrimSpace(body.Metric)
		if pairID == "" {
			return e.BadRequestError("pair is required", nil)
		}
		if metric == "" || len(metric) > 40 {
			return e.BadRequestError("metric is required and must be at most 40 characters", nil)
		}
		if msg := checkMetricTarget(body.Minimum, body.Goal); msg != "" {
			return e.BadRequestError(msg, nil)
		}

		// Membership is the authorisation; the caller's own id is the only user
		// this ever writes, because it comes from the session not the body.
		mem, err := app.FindFirstRecordByFilter("pair_members",
			"pair = {:pair} && user = {:user}",
			dbx.Params{"pair": pairID, "user": e.Auth.Id})
		if err != nil || mem == nil {
			return e.ForbiddenError("you are not a member of that connection", nil)
		}

		rec, err := app.FindFirstRecordByFilter("metric_targets",
			"pair = {:pair} && user = {:user} && metric = {:metric}",
			dbx.Params{"pair": pairID, "user": e.Auth.Id, "metric": metric})
		if err != nil || rec == nil {
			col, cerr := app.FindCollectionByNameOrId("metric_targets")
			if cerr != nil {
				return e.InternalServerError("metric_targets collection missing", cerr)
			}
			rec = core.NewRecord(col)
			rec.Set("pair", pairID)
			rec.Set("user", e.Auth.Id)
			rec.Set("metric", metric)
		}
		rec.Set("minimum", body.Minimum)
		rec.Set("goal", body.Goal)
		if err := app.Save(rec); err != nil {
			return e.InternalServerError("failed to save the target", err)
		}
		return e.JSON(http.StatusOK, map[string]any{
			"ok": true, "metric": metric, "minimum": body.Minimum, "goal": body.Goal,
		})
	}
}

// checkMetricTarget explains why a target cannot be stored, or returns "".
//
// Both zero clears the target (read as the metric's built-in defaults).
// Otherwise the minimum may not exceed the goal, so a bar toward the goal can
// never be overshot by its own minimum marker — the same invariant water holds.
func checkMetricTarget(minimum, goal int) string {
	if minimum < 0 || goal < 0 {
		return "targets cannot be negative"
	}
	if minimum > maxMetricTarget || goal > maxMetricTarget {
		return "targets are too large"
	}
	if minimum > goal {
		return "the minimum cannot be more than the goal"
	}
	return ""
}

// metricTargetOf is a per-member view of one metric's stored target, for a
// generalised reader. Zero in both fields is "none stored".
type metricTargetRow struct {
	User    string `json:"user"`
	Metric  string `json:"metric"`
	Minimum int    `json:"minimum"`
	Goal    int    `json:"goal"`
}

// metricTargets lists every stored target for one metric across a connection's
// members, in a stable order. A failed read is an empty list, so a reader falls
// back to its existing source (the water columns for water, else the built-in
// defaults) exactly as before this collection existed.
func metricTargets(app core.App, pairID, metric string) []metricTargetRow {
	records, err := app.FindRecordsByFilter("metric_targets",
		"pair = {:pair} && metric = {:metric}", "user", 0, 0,
		dbx.Params{"pair": pairID, "metric": metric})
	if err != nil {
		return []metricTargetRow{}
	}
	out := make([]metricTargetRow, 0, len(records))
	for _, r := range records {
		out = append(out, metricTargetRow{
			User:    r.GetString("user"),
			Metric:  r.GetString("metric"),
			Minimum: r.GetInt("minimum"),
			Goal:    r.GetInt("goal"),
		})
	}
	return out
}
