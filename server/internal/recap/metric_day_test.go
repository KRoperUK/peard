package recap_test

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/pocketbase/dbx"
)

// putMetricDay writes a per-day amount through the generic route.
func (w *world) putMetricDay(t *testing.T, token, pair, metric, day string, amount int) (int, string) {
	t.Helper()
	payload := fmt.Sprintf(`{"pair":%q,"metric":%q,"day":%q,"amount":%d,"source":"health"}`,
		pair, metric, day, amount)
	req := httptest.NewRequest(http.MethodPut, "/api/peard/metric/day", strings.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", token)
	}
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	return rec.Code, rec.Body.String()
}

// storedDay reads a member's stored day straight from the collection, so a test
// confirms the row rather than trusting the response.
func (w *world) storedDay(t *testing.T, user, pair, metric, day string) (amount int, found bool) {
	t.Helper()
	rec, err := w.app.FindFirstRecordByFilter("metric_days",
		"pair = {:pair} && user = {:user} && metric = {:metric} && day = {:day}",
		dbx.Params{"pair": pair, "user": user, "metric": metric, "day": day})
	if err != nil || rec == nil {
		return 0, false
	}
	return rec.GetInt("amount"), true
}

func utcDay(offset int) string {
	return time.Now().UTC().AddDate(0, 0, offset).Format("2006-01-02")
}

// A member stores a day's total and it lands on their own row.
func TestMetricDayIsStored(t *testing.T) {
	w := newWorld(t)
	status, body := w.putMetricDay(t, w.aliceTok, w.pair.Id, "steps", utcDay(0), 8400)
	if status != http.StatusOK {
		t.Fatalf("put metric day: %d %s", status, body)
	}
	amount, found := w.storedDay(t, w.alice.Id, w.pair.Id, "steps", utcDay(0))
	if !found {
		t.Fatal("no metric_days row was written")
	}
	if amount != 8400 {
		t.Errorf("stored amount = %d, want 8400", amount)
	}
}

// A second sync on the same day updates the day, it does not make a second one.
func TestMetricDayUpserts(t *testing.T) {
	w := newWorld(t)
	w.putMetricDay(t, w.aliceTok, w.pair.Id, "steps", utcDay(0), 3000)
	status, body := w.putMetricDay(t, w.aliceTok, w.pair.Id, "steps", utcDay(0), 9200)
	if status != http.StatusOK {
		t.Fatalf("second put: %d %s", status, body)
	}

	amount, found := w.storedDay(t, w.alice.Id, w.pair.Id, "steps", utcDay(0))
	if !found || amount != 9200 {
		t.Errorf("stored amount = %d (found %v), want the later 9200", amount, found)
	}
	rows, err := w.app.FindRecordsByFilter("metric_days",
		"pair = {:pair} && user = {:user} && metric = {:metric}",
		"", 0, 0, dbx.Params{"pair": w.pair.Id, "user": w.alice.Id, "metric": "steps"})
	if err != nil {
		t.Fatalf("read days: %v", err)
	}
	if len(rows) != 1 {
		t.Errorf("%d rows for one day, want 1", len(rows))
	}
}

// A stored day is that member's whole day, so it replaces their posts rather
// than adding to them: a connection that also logs steps by hand must not count
// the same steps twice.
func TestAStoredDayReplacesThatMembersPostsForTheStreak(t *testing.T) {
	w := newWorld(t)
	w.postMetricTarget(t, w.aliceTok, w.pair.Id, "steps", 0, 10000)
	w.postMetricTarget(t, w.bobTok, w.pair.Id, "steps", 0, 10000)
	w.metric(t, w.alice, "steps", 15000, 0) // would qualify on its own
	if status, body := w.putMetricDay(t, w.aliceTok, w.pair.Id, "steps", utcDay(0), 9000); status != http.StatusOK {
		t.Fatalf("put metric day: %d %s", status, body)
	}

	got := w.recapWith(t, w.aliceTok, "")

	if len(got.MetricStreaks) != 1 {
		t.Fatalf("metric_streaks = %d, want 1", len(got.MetricStreaks))
	}
	// The stored 9,000 replaces the 15,000 post, so the connection's day is
	// 9,000 and misses its 20,000 goal. Adding them would have passed.
	if got.MetricStreaks[0].Current != 0 {
		t.Errorf("steps streak = %d, want 0 — the stored day replaced the post",
			got.MetricStreaks[0].Current)
	}
	if got.MetricStreaks[0].Mine.Current != 0 {
		t.Errorf("my steps streak = %d, want 0", got.MetricStreaks[0].Mine.Current)
	}
}

// The route is for one's own row only, and only inside a connection.
func TestMetricDayRefusesANonMember(t *testing.T) {
	w := newWorld(t)
	status, _ := w.putMetricDay(t, w.outsiderTok, w.pair.Id, "steps", utcDay(0), 1000)
	if status != http.StatusForbidden {
		t.Errorf("status = %d, want 403", status)
	}
}

// A future row sorts newest in the recap, faking a current streak of one and
// breaking the real run — so a day later than the caller's local today is
// refused. (The caller here has no device zone stored, so their today is UTC.)
func TestMetricDayRefusesAFutureDay(t *testing.T) {
	w := newWorld(t)
	status, body := w.putMetricDay(t, w.aliceTok, w.pair.Id, "steps", utcDay(1), 1000)
	if status != http.StatusBadRequest {
		t.Errorf("status = %d, want 400 (%s)", status, body)
	}
	if _, found := w.storedDay(t, w.alice.Id, w.pair.Id, "steps", utcDay(1)); found {
		t.Error("a future day was stored")
	}
}

// A metric nobody tracks is stored and counted by nothing, so the route only
// takes a built-in or a metric the connection has a target for.
func TestMetricDayRefusesAnUnknownMetric(t *testing.T) {
	w := newWorld(t)
	status, _ := w.putMetricDay(t, w.aliceTok, w.pair.Id, "furlongs", utcDay(0), 1000)
	if status != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", status)
	}
}

// …while a connection's own metric with a target stored syncs like a built-in.
func TestMetricDayAcceptsATrackedCustomMetric(t *testing.T) {
	w := newWorld(t)
	if status, body := w.postMetricTarget(t, w.aliceTok, w.pair.Id, "dog_walk", 0, 5); status != http.StatusOK {
		t.Fatalf("post target: %d %s", status, body)
	}
	status, body := w.putMetricDay(t, w.aliceTok, w.pair.Id, "dog_walk", utcDay(0), 3)
	if status != http.StatusOK {
		t.Fatalf("put metric day: %d %s", status, body)
	}
	amount, found := w.storedDay(t, w.alice.Id, w.pair.Id, "dog_walk", utcDay(0))
	if !found || amount != 3 {
		t.Errorf("stored amount = %d (found %v), want 3", amount, found)
	}
}

// Two devices syncing the same day at once collide on the one-row-per-day
// index; both must succeed as the same stored total, with no 500.
func TestMetricDayConcurrentWritesBothSucceed(t *testing.T) {
	w := newWorld(t)
	const writers = 200
	start := make(chan struct{})
	codes := make([]int, writers)
	var wg sync.WaitGroup
	for i := 0; i < writers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			status, _ := w.putMetricDay(t, w.aliceTok, w.pair.Id, "steps", utcDay(0), 8400)
			codes[i] = status
		}(i)
	}
	close(start)
	wg.Wait()

	for i, code := range codes {
		if code != http.StatusOK {
			t.Errorf("writer %d: status = %d, want 200", i, code)
		}
	}
	amount, found := w.storedDay(t, w.alice.Id, w.pair.Id, "steps", utcDay(0))
	if !found || amount != 8400 {
		t.Errorf("stored amount = %d (found %v), want the synced 8400", amount, found)
	}
}

// A day is a date and an amount is a non-negative figure; neither is a free
// string a client can put anything into.
func TestMetricDayRefusesBadInput(t *testing.T) {
	w := newWorld(t)
	for _, body := range []string{
		`{"pair":"` + w.pair.Id + `","metric":"steps","day":"today","amount":10}`,
		`{"pair":"` + w.pair.Id + `","metric":"steps","day":"2026-10-22","amount":-1}`,
		`{"pair":"` + w.pair.Id + `","metric":"","day":"2026-10-22","amount":10}`,
	} {
		req := httptest.NewRequest(http.MethodPut, "/api/peard/metric/day", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", w.aliceTok)
		rec := httptest.NewRecorder()
		w.mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: status = %d, want 400", body, rec.Code)
		}
	}
}
