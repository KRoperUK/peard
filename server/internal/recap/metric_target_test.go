package recap_test

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/pocketbase/dbx"
)

// postMetricTarget writes a per-metric target through the generic route.
func (w *world) postMetricTarget(t *testing.T, token, pair, metric string, minimum, goal int) (int, string) {
	t.Helper()
	payload := fmt.Sprintf(`{"pair":%q,"metric":%q,"minimum":%d,"goal":%d}`, pair, metric, minimum, goal)
	req := httptest.NewRequest(http.MethodPost, "/api/peard/metric/target", strings.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", token)
	}
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	return rec.Code, rec.Body.String()
}

// storedMetric reads a member's stored target for a metric straight from the
// collection, so a test confirms the row rather than trusting the response.
func (w *world) storedMetric(t *testing.T, user, pair, metric string) (minimum, goal int, found bool) {
	t.Helper()
	rec, err := w.app.FindFirstRecordByFilter("metric_targets",
		"pair = {:pair} && user = {:user} && metric = {:metric}",
		dbx.Params{"pair": pair, "user": user, "metric": metric})
	if err != nil || rec == nil {
		return 0, 0, false
	}
	return rec.GetInt("minimum"), rec.GetInt("goal"), true
}

// A member stores a per-metric target and it lands on their own row.
func TestMetricTargetIsStored(t *testing.T) {
	w := newWorld(t)
	status, body := w.postMetricTarget(t, w.aliceTok, w.pair.Id, "steps", 5000, 10000)
	if status != http.StatusOK {
		t.Fatalf("post metric target: %d %s", status, body)
	}
	min, goal, found := w.storedMetric(t, w.alice.Id, w.pair.Id, "steps")
	if !found {
		t.Fatal("no metric_targets row was written")
	}
	if min != 5000 || goal != 10000 {
		t.Errorf("stored (min=%d goal=%d), want (5000, 10000)", min, goal)
	}
}

// A second write to the same (pair, user, metric) updates the row, it does not
// make a second one — the whole point of keying by metric.
func TestMetricTargetUpserts(t *testing.T) {
	w := newWorld(t)
	w.postMetricTarget(t, w.aliceTok, w.pair.Id, "steps", 5000, 10000)
	w.postMetricTarget(t, w.aliceTok, w.pair.Id, "steps", 6000, 12000)

	n, err := w.app.CountRecords("metric_targets",
		dbx.HashExp{"pair": w.pair.Id, "user": w.alice.Id, "metric": "steps"})
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 1 {
		t.Errorf("rows after two writes = %d, want 1 (an upsert)", n)
	}
	min, goal, _ := w.storedMetric(t, w.alice.Id, w.pair.Id, "steps")
	if min != 6000 || goal != 12000 {
		t.Errorf("stored (min=%d goal=%d), want the updated (6000, 12000)", min, goal)
	}
}

// Different metrics are independent rows for the same member.
func TestMetricTargetsAreIndependentPerMetric(t *testing.T) {
	w := newWorld(t)
	w.postMetricTarget(t, w.aliceTok, w.pair.Id, "steps", 5000, 10000)
	w.postMetricTarget(t, w.aliceTok, w.pair.Id, "exercise", 20, 30)

	if _, g, _ := w.storedMetric(t, w.alice.Id, w.pair.Id, "steps"); g != 10000 {
		t.Errorf("steps goal = %d, want 10000", g)
	}
	if _, g, _ := w.storedMetric(t, w.alice.Id, w.pair.Id, "exercise"); g != 30 {
		t.Errorf("exercise goal = %d, want 30", g)
	}
}

// Both zero clears the target (read later as the metric's built-in defaults).
func TestMetricTargetBothZeroIsAllowed(t *testing.T) {
	w := newWorld(t)
	if status, body := w.postMetricTarget(t, w.aliceTok, w.pair.Id, "steps", 0, 0); status != http.StatusOK {
		t.Fatalf("both-zero target rejected: %d %s", status, body)
	}
}

// The minimum may not exceed the goal, so a bar can never overshoot its marker.
func TestMetricTargetRejectsMinimumAboveGoal(t *testing.T) {
	w := newWorld(t)
	if status, _ := w.postMetricTarget(t, w.aliceTok, w.pair.Id, "steps", 10000, 5000); status != http.StatusBadRequest {
		t.Errorf("minimum>goal status = %d, want 400", status)
	}
}

// An empty metric slug is refused — a target has to be about something.
func TestMetricTargetRequiresAMetric(t *testing.T) {
	w := newWorld(t)
	if status, _ := w.postMetricTarget(t, w.aliceTok, w.pair.Id, "", 5000, 10000); status != http.StatusBadRequest {
		t.Errorf("empty-metric status = %d, want 400", status)
	}
}

// A non-member cannot write a target into a connection they are not in.
func TestMetricTargetRefusesNonMembers(t *testing.T) {
	w := newWorld(t)
	status, _ := w.postMetricTarget(t, w.outsiderTok, w.pair.Id, "steps", 5000, 10000)
	if status != http.StatusForbidden {
		t.Errorf("outsider status = %d, want 403", status)
	}
	if _, _, found := w.storedMetric(t, w.outsider.Id, w.pair.Id, "steps"); found {
		t.Error("an outsider's target was written")
	}
}

// A write needs a session: no auth, no target.
func TestMetricTargetRequiresAuth(t *testing.T) {
	w := newWorld(t)
	if status, _ := w.postMetricTarget(t, "", w.pair.Id, "steps", 5000, 10000); status == http.StatusOK {
		t.Error("an unauthenticated write succeeded")
	}
}
