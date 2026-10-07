package recap

import (
	"net/http"
	"strings"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// Per-person daily water targets (#335).
//
//	POST /api/peard/water/target  { pair, minimum, recommended }  -> { ok, minimum, recommended }
//
// Each member owns their own target — a daily minimum and a recommended amount,
// in millilitres — stored on their membership row. Everybody in the connection
// reads everybody's through the recap payload (`water_targets`); only the owner
// writes theirs, and only through this route, which sets exactly these two
// fields on the caller's own membership. See the 1787529600_peard_water_targets
// migration for why this is a route rather than a collection UpdateRule.

// maxWaterTarget is the largest target a member can store: the same ceiling as
// one moment's amount and the app's `WaterAmount.maximum`.
const maxWaterTarget = 5000

// memberTarget is one member's stored target. Zero in both fields is "none
// stored", which readers answer with the built-in amounts.
type memberTarget struct {
	User        string `json:"user"`
	Minimum     int    `json:"minimum"`
	Recommended int    `json:"recommended"`
}

func registerTarget(se *core.ServeEvent) {
	se.Router.POST("/api/peard/water/target", targetHandler(se.App)).Bind(apis.RequireAuth())
}

func targetHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			Pair        string `json:"pair" form:"pair"`
			Minimum     int    `json:"minimum" form:"minimum"`
			Recommended int    `json:"recommended" form:"recommended"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}
		pairID := strings.TrimSpace(body.Pair)
		if pairID == "" {
			return e.BadRequestError("pair is required", nil)
		}
		if msg := checkTarget(body.Minimum, body.Recommended); msg != "" {
			return e.BadRequestError(msg, nil)
		}

		// Membership is the authorisation, and the caller's own row is the only
		// one this ever finds: the user comes from the session, never the body.
		mem, err := app.FindFirstRecordByFilter("pair_members",
			"pair = {:pair} && user = {:user}",
			dbx.Params{"pair": pairID, "user": e.Auth.Id})
		if err != nil || mem == nil {
			return e.ForbiddenError("you are not a member of that connection", nil)
		}
		mem.Set("water_minimum", body.Minimum)
		mem.Set("water_recommended", body.Recommended)
		if err := app.Save(mem); err != nil {
			return e.InternalServerError("failed to save the target", err)
		}
		return e.JSON(http.StatusOK, map[string]any{
			"ok": true, "minimum": body.Minimum, "recommended": body.Recommended,
		})
	}
}

// checkTarget explains why a target cannot be stored, or returns "".
//
// Both zero is allowed and clears the target. Otherwise the minimum may not
// exceed the recommended amount, so a bar toward the goal can never be
// overshot by its own minimum marker.
func checkTarget(minimum, recommended int) string {
	if minimum < 0 || recommended < 0 {
		return "targets cannot be negative"
	}
	if minimum > maxWaterTarget || recommended > maxWaterTarget {
		return "targets cannot be more than 5000 ml"
	}
	if minimum > recommended {
		return "the minimum cannot be more than the goal"
	}
	return ""
}

// memberTargets lists every member's stored target, in a stable order so
// the same connection does not reorder itself between two requests. A failed
// read is an empty list: the recap then falls back to the caller's own number,
// which is what it did before targets lived here.
func memberTargets(app core.App, pairID string) []memberTarget {
	records, err := app.FindRecordsByFilter("pair_members", "pair = {:pair}", "id", 0, 0,
		dbx.Params{"pair": pairID})
	if err != nil {
		return []memberTarget{}
	}
	targets := make([]memberTarget, 0, len(records))
	for _, r := range records {
		targets = append(targets, memberTarget{
			User:        r.GetString("user"),
			Minimum:     r.GetInt("water_minimum"),
			Recommended: r.GetInt("water_recommended"),
		})
	}
	return targets
}

// streakTarget is the daily amount the connection's combined water has to reach
// for a day to count toward the water streak.
//
// The streak is the connection's, not a person's, so it cannot be judged by one
// viewer's number — two members would then see different streaks for the same
// days. It is the sum of every member's recommended amount instead: the goal the
// pair set between them, and the same for whoever asks.
//
// A member who stored no target contributes `fallback` (what the caller's app
// sent, else the built-in amount), and when *nobody* stored one the answer is
// just `fallback`, unsummed: a connection that has never heard of per-person
// targets keeps being judged exactly as it was, by its caller's single number.
func streakTarget(targets []memberTarget, fallback int) int {
	stored := false
	for _, t := range targets {
		if t.Recommended > 0 {
			stored = true
			break
		}
	}
	if !stored {
		return fallback
	}
	total := 0
	for _, t := range targets {
		switch {
		case t.Recommended > 0:
			total += t.Recommended
		case fallback > 0:
			total += fallback
		}
	}
	return total
}
