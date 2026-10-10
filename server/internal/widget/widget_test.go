// The widget feed's unread count.
//
// External to `widget` so the real schema can come from blank-importing
// `peard/migrations`, which imports this package.
//
// The widget package had no server tests before this. These cover the one thing
// most likely to break silently — the feed is fetched by an extension with no
// screen to report an error on, so a wrong or missing field shows up as a widget
// that quietly says the wrong thing rather than as a failure anybody sees.
package widget_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"slices"
	"strconv"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
	"github.com/pocketbase/pocketbase/tools/types"

	"peard/internal/widget"

	_ "peard/migrations"
)

type feedWorld struct {
	app *tests.TestApp
	mux http.Handler

	alice, bob *core.Record
	pair       *core.Record
	token      string
}

func newFeedWorld(t *testing.T) *feedWorld {
	t.Helper()

	dir, err := os.MkdirTemp("", "peard-widget-test-*")
	if err != nil {
		t.Fatalf("temp dir: %v", err)
	}
	app, err := tests.NewTestApp(dir)
	if err != nil {
		os.RemoveAll(dir)
		t.Fatalf("new test app: %v", err)
	}
	t.Cleanup(func() {
		app.Cleanup()
		os.RemoveAll(dir)
	})

	widget.Register(app)

	w := &feedWorld{app: app}
	w.alice = w.newUser(t, "alice@example.com", "Alice")
	w.bob = w.newUser(t, "bob@example.com", "Bob")
	w.pair = w.newRecord(t, "pairs", map[string]any{"name": "Flatmates"})
	w.newRecord(t, "pair_members", map[string]any{"pair": w.pair.Id, "user": w.alice.Id, "role": "owner"})
	w.newRecord(t, "pair_members", map[string]any{"pair": w.pair.Id, "user": w.bob.Id, "role": "member"})
	w.token = "widget-token-for-alice"
	w.newRecord(t, "widget_tokens", map[string]any{"user": w.alice.Id, "token": w.token})

	router, err := apis.NewRouter(app)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}
	event := new(core.ServeEvent)
	event.App = app
	event.Router = router
	if err := app.OnServe().Trigger(event, func(e *core.ServeEvent) error {
		mux, err := e.Router.BuildMux()
		if err != nil {
			return err
		}
		w.mux = mux
		return nil
	}); err != nil {
		t.Fatalf("build mux: %v", err)
	}
	return w
}

func (w *feedWorld) newUser(t *testing.T, email, name string) *core.Record {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("users collection: %v", err)
	}
	r := core.NewRecord(col)
	r.SetEmail(email)
	r.SetVerified(true)
	r.SetPassword("Password123!")
	r.Set("display_name", name)
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save user: %v", err)
	}
	return r
}

func (w *feedWorld) newRecord(t *testing.T, collection string, fields map[string]any) *core.Record {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId(collection)
	if err != nil {
		t.Fatalf("%s collection: %v", collection, err)
	}
	r := core.NewRecord(col)
	for k, v := range fields {
		r.Set(k, v)
	}
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save %s: %v", collection, err)
	}
	return r
}

func (w *feedWorld) newPost(t *testing.T, author *core.Record, note string) *core.Record {
	t.Helper()
	return w.newRecord(t, "posts", map[string]any{
		"pair": w.pair.Id, "author": author.Id,
		"type": "event", "event_kind": "beer", "note": note,
	})
}

// unread fetches the feed and returns its `unread`, failing on anything that is
// not a clean 200 — so a broken route can never be read as "nothing new".
func (w *feedWorld) unread(t *testing.T) int {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/peard/widget/feed?token="+w.token, nil)
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("feed: got %d, body %s", rec.Code, rec.Body.String())
	}
	var parsed struct {
		State  string `json:"state"`
		Unread int    `json:"unread"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &parsed); err != nil {
		t.Fatalf("decode feed: %v (body %s)", err, rec.Body.String())
	}
	return parsed.Unread
}

func TestFeedReportsSomebodyElsesMomentAsUnread(t *testing.T) {
	w := newFeedWorld(t)
	// Unread means created strictly after Alice last looked, and timestamps are
	// to the millisecond: on a warm run her membership and Bob's post could
	// share one and the post would not count. Having her look a second ago
	// makes the order the test means independent of how fast it runs.
	membership, err := w.app.FindFirstRecordByFilter("pair_members",
		"pair = {:pair} && user = {:user}",
		map[string]any{"pair": w.pair.Id, "user": w.alice.Id})
	if err != nil {
		t.Fatalf("membership: %v", err)
	}
	membership.Set("last_seen_at", types.NowDateTime().Add(-time.Second))
	if err := w.app.Save(membership); err != nil {
		t.Fatalf("stamp: %v", err)
	}
	w.newPost(t, w.bob, "from Bob")

	if got := w.unread(t); got != 1 {
		t.Fatalf("got %d, want 1", got)
	}
}

// The widget is Alice's; her own moments are not news to her, exactly as in the
// app's rail and the push badge.
func TestFeedDoesNotCountYourOwnMoments(t *testing.T) {
	w := newFeedWorld(t)
	w.newPost(t, w.alice, "mine")

	if got := w.unread(t); got != 0 {
		t.Fatalf("got %d, want 0", got)
	}
}

// feedWater issues GET /api/peard/widget/feed and returns the decoded water
// block, so the complication (#364) can draw today's progress toward the goal.
func (w *feedWorld) feedWater(t *testing.T) (todayML, goalML int, present bool) {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/peard/widget/feed?token="+w.token, nil)
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("feed: got %d, body %s", rec.Code, rec.Body.String())
	}
	var parsed struct {
		Water *struct {
			TodayML int `json:"today_ml"`
			GoalML  int `json:"goal_ml"`
		} `json:"water"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &parsed); err != nil {
		t.Fatalf("decode feed: %v (body %s)", err, rec.Body.String())
	}
	if parsed.Water == nil {
		return 0, 0, false
	}
	return parsed.Water.TodayML, parsed.Water.GoalML, true
}

// The feed carries today's connection water and the summed goal, so the watch's
// water complication can draw a ring without the recap route (#364).
func TestFeedCarriesTodaysWaterAgainstTheGoal(t *testing.T) {
	w := newFeedWorld(t)
	w.setWaterTarget(t, w.alice, 1500)
	w.setWaterTarget(t, w.bob, 2500) // summed goal 4000
	w.newWater(t, w.alice, 900)
	w.newWater(t, w.bob, 600) // 1500 together today

	todayML, goalML, present := w.feedWater(t)
	if !present {
		t.Fatal("feed carried no water block")
	}
	if todayML != 1500 {
		t.Errorf("today_ml = %d, want 1500 (900 + 600)", todayML)
	}
	if goalML != 4000 {
		t.Errorf("goal_ml = %d, want 4000 (1500 + 2500)", goalML)
	}
}

// Nobody stored a target: the goal is one built-in amount, matching the recap's
// streakTarget, so the complication's ring reads the same as the streak's.
func TestFeedWaterGoalFallsBackWhenNobodyStoredOne(t *testing.T) {
	w := newFeedWorld(t)
	w.newWater(t, w.alice, 500)

	todayML, goalML, present := w.feedWater(t)
	if !present {
		t.Fatal("feed carried no water block")
	}
	if todayML != 500 {
		t.Errorf("today_ml = %d, want 500", todayML)
	}
	if goalML != 2000 {
		t.Errorf("goal_ml = %d, want the built-in 2000 when nobody stored a target", goalML)
	}
}

// feedStreak fetches the feed and returns its streak block, so the watch's
// streak complication (#378) can read the connection's day streak without the
// recap route.
func (w *feedWorld) feedStreak(t *testing.T) (current, best int, present bool) {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/peard/widget/feed?token="+w.token, nil)
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("feed: got %d, body %s", rec.Code, rec.Body.String())
	}
	var parsed struct {
		Streak *struct {
			Current int `json:"current"`
			Best    int `json:"best"`
		} `json:"streak"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &parsed); err != nil {
		t.Fatalf("decode feed: %v (body %s)", err, rec.Body.String())
	}
	if parsed.Streak == nil {
		return 0, 0, false
	}
	return parsed.Streak.Current, parsed.Streak.Best, true
}

// newMomentDaysAgo seeds a moment dated n days before now, so a streak can be
// built across consecutive days.
func (w *feedWorld) newMomentDaysAgo(t *testing.T, author *core.Record, daysAgo int) *core.Record {
	t.Helper()
	when := time.Now().UTC().AddDate(0, 0, -daysAgo)
	return w.newRecord(t, "posts", map[string]any{
		"pair": w.pair.Id, "author": author.Id,
		"type": "event", "event_kind": "beer",
		"happened_at": when.Format(types.DefaultDateLayout),
	})
}

// The feed carries the connection's day streak, so the watch's streak
// complication can show it without the recap route (#378). Moments today and
// yesterday are a live streak of two.
func TestFeedCarriesTheConnectionStreak(t *testing.T) {
	w := newFeedWorld(t)
	w.newMomentDaysAgo(t, w.alice, 0) // today
	w.newMomentDaysAgo(t, w.bob, 1)   // yesterday — anybody's moment keeps it alive

	current, best, present := w.feedStreak(t)
	if !present {
		t.Fatal("feed carried no streak block")
	}
	if current != 2 {
		t.Errorf("current streak = %d, want 2 (today + yesterday)", current)
	}
	if best < 2 {
		t.Errorf("best streak = %d, want at least 2", best)
	}
}

// A connection with nothing logged has a zero streak, not a missing block, so
// the complication can draw "no streak yet" rather than going blank.
func TestFeedStreakIsZeroWhenNothingLogged(t *testing.T) {
	w := newFeedWorld(t)

	current, _, present := w.feedStreak(t)
	if !present {
		t.Fatal("feed carried no streak block")
	}
	if current != 0 {
		t.Errorf("current streak = %d, want 0 for an empty connection", current)
	}
}

// feedMetrics issues the feed and returns its `metrics` array (#386).
func (w *feedWorld) feedMetrics(t *testing.T) []map[string]any {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/peard/widget/feed?token="+w.token, nil)
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("feed: got %d, body %s", rec.Code, rec.Body.String())
	}
	var parsed struct {
		Metrics []map[string]any `json:"metrics"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &parsed); err != nil {
		t.Fatalf("decode feed: %v (body %s)", err, rec.Body.String())
	}
	return parsed.Metrics
}

// metricBlock returns the summary for one slug, or nil if absent.
func metricBlock(metrics []map[string]any, slug string) map[string]any {
	for _, m := range metrics {
		if m["slug"] == slug {
			return m
		}
	}
	return nil
}

// newMetricPost seeds an amount-bearing post of a metric kind today.
func (w *feedWorld) newMetricPost(t *testing.T, author *core.Record, kind string, amount int) {
	t.Helper()
	w.newRecord(t, "posts", map[string]any{
		"pair": w.pair.Id, "author": author.Id,
		"type": "event", "event_kind": kind, "amount": amount,
		"happened_at": time.Now().UTC().Format(types.DefaultDateLayout),
	})
}

// setMetricTarget stores a member's goal for a metric in metric_targets.
func (w *feedWorld) setMetricTarget(t *testing.T, user *core.Record, metric string, goal int) {
	t.Helper()
	w.newRecord(t, "metric_targets", map[string]any{
		"pair": w.pair.Id, "user": user.Id, "metric": metric, "minimum": 0, "goal": goal,
	})
}

// A connection logging steps today shows a steps metric block with the summed
// goal — the generalisation of the water block to any metric (#386).
func TestFeedCarriesTrackedMetrics(t *testing.T) {
	w := newFeedWorld(t)
	w.newMetricPost(t, w.alice, "steps", 4000)
	w.newMetricPost(t, w.bob, "steps", 3000) // 7000 together
	w.setMetricTarget(t, w.alice, "steps", 8000)
	w.setMetricTarget(t, w.bob, "steps", 12000) // summed goal 20000

	steps := metricBlock(w.feedMetrics(t), "steps")
	if steps == nil {
		t.Fatal("feed carried no steps metric block")
	}
	if got := int(steps["today"].(float64)); got != 7000 {
		t.Errorf("steps today = %d, want 7000", got)
	}
	if got := int(steps["goal"].(float64)); got != 20000 {
		t.Errorf("steps goal = %d, want 20000 (8000 + 12000)", got)
	}
	if steps["unit"] != "count" {
		t.Errorf("steps unit = %v, want count", steps["unit"])
	}
}

// A metric nobody tracks is left out, so the client never draws an empty ring.
func TestFeedOmitsUntrackedMetrics(t *testing.T) {
	w := newFeedWorld(t)
	w.newMetricPost(t, w.alice, "steps", 5000)

	metrics := w.feedMetrics(t)
	if metricBlock(metrics, "steps") == nil {
		t.Error("steps was logged but is absent from the feed")
	}
	if metricBlock(metrics, "exercise") != nil {
		t.Error("exercise is tracked by nobody but appears in the feed")
	}
}

// A member with no stored goal contributes the metric's default, as
// waterSummary falls back.
func TestFeedMetricGoalFallsBackToDefault(t *testing.T) {
	w := newFeedWorld(t)
	w.newMetricPost(t, w.alice, "steps", 1000)
	w.setMetricTarget(t, w.alice, "steps", 8000) // bob set none

	steps := metricBlock(w.feedMetrics(t), "steps")
	if steps == nil {
		t.Fatal("no steps block")
	}
	// alice 8000 + bob default 10000 = 18000.
	if got := int(steps["goal"].(float64)); got != 18000 {
		t.Errorf("steps goal = %d, want 18000 (8000 + default 10000)", got)
	}
}

func (w *feedWorld) newWater(t *testing.T, author *core.Record, ml int) *core.Record {
	t.Helper()
	return w.newRecord(t, "posts", map[string]any{
		"pair": w.pair.Id, "author": author.Id,
		"type": "event", "event_kind": "water", "amount": ml,
		"happened_at": time.Now().UTC().Format(types.DefaultDateLayout),
	})
}

func (w *feedWorld) setWaterTarget(t *testing.T, user *core.Record, recommended int) {
	t.Helper()
	mem, err := w.app.FindFirstRecordByFilter("pair_members",
		"pair = {:pair} && user = {:user}",
		map[string]any{"pair": w.pair.Id, "user": user.Id})
	if err != nil {
		t.Fatalf("membership: %v", err)
	}
	mem.Set("water_recommended", recommended)
	if err := w.app.Save(mem); err != nil {
		t.Fatalf("save target: %v", err)
	}
}

func TestFeedUnreadClearsOnceSeen(t *testing.T) {
	w := newFeedWorld(t)
	w.newPost(t, w.bob, "from Bob")

	membership, err := w.app.FindFirstRecordByFilter("pair_members",
		"pair = {:pair} && user = {:user}",
		map[string]any{"pair": w.pair.Id, "user": w.alice.Id})
	if err != nil {
		t.Fatalf("membership: %v", err)
	}
	membership.Set("last_seen_at", types.NowDateTime().Add(time.Second))
	if err := w.app.Save(membership); err != nil {
		t.Fatalf("stamp: %v", err)
	}

	if got := w.unread(t); got != 0 {
		t.Fatalf("got %d, want 0", got)
	}
}

// connections issues GET /api/peard/widget/connections and returns the decoded
// list, so the two tests below differ only in the query they ask.
func (w *feedWorld) connections(t *testing.T, query string) []map[string]any {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/peard/widget/connections?token="+w.token+query, nil)
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("connections: got %d, body %s", rec.Code, rec.Body.String())
	}
	var parsed struct {
		Connections []map[string]any `json:"connections"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &parsed); err != nil {
		t.Fatalf("decode connections: %v (body %s)", err, rec.Body.String())
	}
	return parsed.Connections
}

// `?moments=1` exists so the Shortcuts picker can offer every connection's
// catalogue at once. It used to fetch a whole feed per connection — tallies,
// latest post, unread count — to read one list out of each.
func TestConnectionsCarryTheirMomentsWhenAsked(t *testing.T) {
	w := newFeedWorld(t)
	w.newRecord(t, "moment_kinds", map[string]any{
		"pair": w.pair.Id, "slug": "dog_walk", "emoji": "🐕", "label": "Dog walk", "created_by": w.alice.Id,
	})

	connections := w.connections(t, "&moments=1")
	if len(connections) != 1 {
		t.Fatalf("got %d connections, want 1", len(connections))
	}

	moments, ok := connections[0]["moments"].([]any)
	if !ok {
		t.Fatalf("expected moments on the connection, got %v", connections[0])
	}
	var labels []string
	for _, moment := range moments {
		labels = append(labels, moment.(map[string]any)["label"].(string))
	}
	// The built-ins are there too — every connection can log those — so this
	// asserts the custom one arrived rather than the exact list.
	if !slices.Contains(labels, "Dog walk") {
		t.Fatalf("expected the published moment in %v", labels)
	}
	if !slices.Contains(labels, "Beer") {
		t.Fatalf("expected the built-ins in %v", labels)
	}
}

// Without the flag the response is what it always was. The widget's own
// configuration picker does not want catalogues, and building them walks
// moment_kinds once per connection.
func TestConnectionsOmitMomentsByDefault(t *testing.T) {
	w := newFeedWorld(t)
	w.newRecord(t, "moment_kinds", map[string]any{
		"pair": w.pair.Id, "slug": "dog_walk", "emoji": "🐕", "label": "Dog walk", "created_by": w.alice.Id,
	})

	connections := w.connections(t, "")

	if _, present := connections[0]["moments"]; present {
		t.Fatalf("expected no moments key, got %v", connections[0])
	}
}

// feedToday fetches the feed with an extra query string and returns how many
// moments it counted today, in the older beer/loo shape and across tallies.
func (w *feedWorld) feedToday(t *testing.T, extra string) (beer int, tallied int) {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/peard/widget/feed?token="+w.token+extra, nil)
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("feed%s: got %d, body %s", extra, rec.Code, rec.Body.String())
	}
	var parsed struct {
		Counts  map[string]int `json:"counts"`
		Tallies []struct {
			Count int `json:"count"`
		} `json:"tallies"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &parsed); err != nil {
		t.Fatalf("decode feed: %v (body %s)", err, rec.Body.String())
	}
	for _, tally := range parsed.Tallies {
		tallied += tally.Count
	}
	return parsed.Counts["beer"], tallied
}

// zoneAtLocalHour finds a fixed-offset zone whose clock currently reads the
// given hour, so a test can put a moment either side of that zone's midnight
// whatever time it is run. Etc/GMT's signs are the POSIX way round: Etc/GMT-9
// is nine hours ahead of UTC.
func zoneAtLocalHour(t *testing.T, now time.Time, hour int) (string, *time.Location) {
	t.Helper()
	for offset := -12; offset <= 13; offset++ {
		name := "Etc/GMT"
		switch {
		case offset > 0:
			name += "-" + strconv.Itoa(offset)
		case offset < 0:
			name += "+" + strconv.Itoa(-offset)
		}
		loc, err := time.LoadLocation(name)
		if err != nil {
			t.Fatalf("load %s: %v", name, err)
		}
		if now.In(loc).Hour() == hour {
			return name, loc
		}
	}
	t.Fatalf("no zone has local hour %d at %v", hour, now)
	return "", nil
}

// The widget's "today" is the phone's. A moment at half past eleven last night,
// where the phone is, is yesterday's — even though, an hour further east, the
// same instant is half past midnight today.
func TestFeedCountsTodayInTheWidgetsZone(t *testing.T) {
	w := newFeedWorld(t)
	now := time.Now()
	justPastMidnight, loc := zoneAtLocalHour(t, now, 0)
	lastNight := now.Add(-time.Duration(now.In(loc).Minute()+30) * time.Minute)
	w.newRecord(t, "posts", map[string]any{
		"pair": w.pair.Id, "author": w.bob.Id, "type": "event", "event_kind": "beer",
		"happened_at": lastNight.UTC().Format(types.DefaultDateLayout),
	})
	anHourAhead, _ := zoneAtLocalHour(t, now, 1)

	if beer, tallied := w.feedToday(t, "&tz="+url.QueryEscape(justPastMidnight)); beer != 0 || tallied != 0 {
		t.Errorf("tz=%s: counted %d beer, %d tallied; the moment was last night there", justPastMidnight, beer, tallied)
	}
	if beer, tallied := w.feedToday(t, "&tz="+url.QueryEscape(anHourAhead)); beer != 1 || tallied != 1 {
		t.Errorf("tz=%s: counted %d beer, %d tallied; the moment was after midnight there", anHourAhead, beer, tallied)
	}
}

// A zone the server does not recognise is not an error: the widget has no
// screen to show one on. It gets the server's day, as every widget did before
// it sent a zone.
func TestFeedIgnoresAZoneItCannotRead(t *testing.T) {
	w := newFeedWorld(t)
	w.newRecord(t, "posts", map[string]any{
		"pair": w.pair.Id, "author": w.bob.Id, "type": "event", "event_kind": "beer",
		"happened_at": time.Now().UTC().Format(types.DefaultDateLayout),
	})

	withNone, _ := w.feedToday(t, "")
	for _, bad := range []string{"Mars%2FOlympus_Mons", "..%2F..%2Fetc%2Fpasswd", "Local", "%2B05%3A30"} {
		if beer, _ := w.feedToday(t, "&tz="+bad); beer != withNone {
			t.Errorf("tz=%s: counted %d, want the same %d as no zone", bad, beer, withNone)
		}
	}
}
