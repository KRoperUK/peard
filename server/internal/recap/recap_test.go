// Package recap_test is external to `recap` on purpose: these tests need the
// real Pear'd schema, which comes from blank-importing `peard/migrations`, and
// that package imports the route packages.
package recap_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"peard/internal/posts"
	"peard/internal/recap"

	_ "peard/migrations"
)

type world struct {
	app *tests.TestApp
	mux http.Handler

	alice, bob       *core.Record
	aliceTok, bobTok string
	pair             *core.Record
	outsider         *core.Record
	outsiderTok      string
}

type response struct {
	Pair   string `json:"pair"`
	Total  int    `json:"total"`
	Mine   int    `json:"mine"`
	Others int    `json:"others"`
	Kinds  []struct {
		Kind  string `json:"kind"`
		Emoji string `json:"emoji"`
		Label string `json:"label"`
		Count int    `json:"count"`
	} `json:"kinds"`
	Busiest *struct {
		Date  string `json:"date"`
		Count int    `json:"count"`
	} `json:"busiest"`
	Streak struct {
		Current int `json:"current"`
		Best    int `json:"best"`
	} `json:"streak"`
	WaterStreak struct {
		Current int `json:"current"`
		Best    int `json:"best"`
	} `json:"water_streak"`
	WaterTargets []struct {
		User        string `json:"user"`
		Minimum     int    `json:"minimum"`
		Recommended int    `json:"recommended"`
	} `json:"water_targets"`
}

// MARK: The window

func TestTheWindowSplitsYoursFromTheirs(t *testing.T) {
	w := newWorld(t)
	w.post(t, w.alice, "coffee", 0)
	w.post(t, w.alice, "coffee", 1)
	w.post(t, w.bob, "beer", 2)

	got := w.recap(t, w.aliceTok)

	if got.Total != 3 || got.Mine != 2 || got.Others != 1 {
		t.Errorf("total=%d mine=%d others=%d, want 3/2/1", got.Total, got.Mine, got.Others)
	}
}

// Anything older than the window is not this week's news, however much of it
// there is.
func TestMomentsOlderThanTheWindowAreNotCounted(t *testing.T) {
	w := newWorld(t)
	w.post(t, w.alice, "coffee", 0)
	for day := 8; day < 14; day++ {
		w.post(t, w.alice, "beer", day)
	}

	got := w.recap(t, w.aliceTok)

	if got.Total != 1 {
		t.Errorf("total=%d, want only the one inside the window", got.Total)
	}
}

// Most-logged first: the summary's first line is meant to be the headline.
func TestKindsComeBackMostLoggedFirst(t *testing.T) {
	w := newWorld(t)
	w.post(t, w.alice, "beer", 0)
	for i := 0; i < 3; i++ {
		w.post(t, w.alice, "coffee", i)
	}
	w.post(t, w.bob, "coffee", 1)

	got := w.recap(t, w.aliceTok)

	if len(got.Kinds) != 2 {
		t.Fatalf("kinds = %d, want 2", len(got.Kinds))
	}
	if got.Kinds[0].Kind != "coffee" || got.Kinds[0].Count != 4 {
		t.Errorf("first kind = %s (%d), want coffee (4)", got.Kinds[0].Kind, got.Kinds[0].Count)
	}
	if got.Kinds[0].Emoji == "" || got.Kinds[0].Label == "" {
		t.Error("a kind with no emoji or label cannot be drawn")
	}
}

func TestTheBusiestDayIsReported(t *testing.T) {
	w := newWorld(t)
	w.post(t, w.alice, "coffee", 0)
	for i := 0; i < 3; i++ {
		w.post(t, w.alice, "beer", 2)
	}

	got := w.recap(t, w.aliceTok)

	if got.Busiest == nil {
		t.Fatal("no busiest day")
	}
	if got.Busiest.Count != 3 {
		t.Errorf("busiest count = %d, want 3", got.Busiest.Count)
	}
}

// A connection nobody has logged anything in yet must answer, not fail. It is
// the first thing a new pair sees.
func TestAnEmptyConnectionSummarisesToZero(t *testing.T) {
	w := newWorld(t)

	got := w.recap(t, w.aliceTok)

	if got.Total != 0 || got.Streak.Current != 0 || got.Streak.Best != 0 {
		t.Errorf("total=%d streak=%d/%d, want zeroes", got.Total, got.Streak.Current, got.Streak.Best)
	}
	if got.Busiest != nil {
		t.Error("there is no busiest day when there are no days")
	}
}

// MARK: Streaks

func TestConsecutiveDaysAreAStreak(t *testing.T) {
	w := newWorld(t)
	for day := 0; day < 5; day++ {
		w.post(t, w.alice, "coffee", day)
	}

	got := w.recap(t, w.aliceTok)

	if got.Streak.Current != 5 {
		t.Errorf("current streak = %d, want 5", got.Streak.Current)
	}
}

// Anybody's moment keeps it alive. Requiring everybody would make one busy
// Tuesday everyone's fault, which is the opposite of what a shared streak is
// for.
func TestAnybodysMomentKeepsTheStreakAlive(t *testing.T) {
	w := newWorld(t)
	w.post(t, w.alice, "coffee", 0)
	w.post(t, w.bob, "beer", 1)
	w.post(t, w.alice, "coffee", 2)

	got := w.recap(t, w.aliceTok)

	if got.Streak.Current != 3 {
		t.Errorf("current streak = %d, want 3", got.Streak.Current)
	}
}

func TestADayWithNothingInItEndsTheStreak(t *testing.T) {
	w := newWorld(t)
	w.post(t, w.alice, "coffee", 0)
	w.post(t, w.alice, "coffee", 1)
	// Nothing on day 2.
	w.post(t, w.alice, "coffee", 3)
	w.post(t, w.alice, "coffee", 4)
	w.post(t, w.alice, "coffee", 5)

	got := w.recap(t, w.aliceTok)

	if got.Streak.Current != 2 {
		t.Errorf("current streak = %d, want 2", got.Streak.Current)
	}
	if got.Streak.Best != 3 {
		t.Errorf("best streak = %d, want the three-day run", got.Streak.Best)
	}
}

// A streak is alive until a day passes with nothing in it. Somebody who logged
// something yesterday and has not opened the app yet this morning has not
// broken anything.
func TestYesterdayStillCountsAsAlive(t *testing.T) {
	w := newWorld(t)
	w.post(t, w.alice, "coffee", 1)
	w.post(t, w.alice, "coffee", 2)

	got := w.recap(t, w.aliceTok)

	if got.Streak.Current != 2 {
		t.Errorf("current streak = %d, want 2 — yesterday is not a break", got.Streak.Current)
	}
}

func TestAStreakThatEndedIsNotCurrent(t *testing.T) {
	w := newWorld(t)
	for day := 5; day < 10; day++ {
		w.post(t, w.alice, "coffee", day)
	}

	got := w.recap(t, w.aliceTok)

	if got.Streak.Current != 0 {
		t.Errorf("current streak = %d, want 0 — the last moment was days ago", got.Streak.Current)
	}
	if got.Streak.Best != 5 {
		t.Errorf("best streak = %d, want 5", got.Streak.Best)
	}
}

// Several moments in one day are one day, not several.
func TestManyMomentsInADayAreStillOneDay(t *testing.T) {
	w := newWorld(t)
	for i := 0; i < 6; i++ {
		w.post(t, w.alice, "coffee", 0)
	}

	got := w.recap(t, w.aliceTok)

	if got.Streak.Current != 1 {
		t.Errorf("current streak = %d, want 1", got.Streak.Current)
	}
}

// Photos have no `event_kind` and are excluded from the tallies, but they are
// still somebody turning up.
func TestAPhotoKeepsTheStreakAlive(t *testing.T) {
	w := newWorld(t)
	w.photo(t, w.alice, 0)
	w.photo(t, w.alice, 1)

	got := w.recap(t, w.aliceTok)

	if got.Streak.Current != 2 {
		t.Errorf("current streak = %d, want 2", got.Streak.Current)
	}
	if got.Total != 0 {
		t.Errorf("total = %d — a photo is not an event moment", got.Total)
	}
}

// MARK: Who may

func TestSomebodyElsesConnectionIsRefused(t *testing.T) {
	w := newWorld(t)
	w.post(t, w.alice, "coffee", 0)

	status, body := w.do(t, "/api/peard/recap?pair="+w.pair.Id, w.outsiderTok)

	if status != 403 {
		t.Fatalf("outsider got %d %s", status, body)
	}
}

func TestARecapNeedsASession(t *testing.T) {
	w := newWorld(t)

	if status, _ := w.do(t, "/api/peard/recap?pair="+w.pair.Id, ""); status != 401 {
		t.Fatalf("unauthenticated recap = %d, want 401", status)
	}
}

func TestAMissingPairIsRefused(t *testing.T) {
	w := newWorld(t)

	if status, _ := w.do(t, "/api/peard/recap", w.aliceTok); status != 400 {
		t.Fatal("a recap with no connection is not a question that can be answered")
	}
}

// MARK: Helpers

func newWorld(t *testing.T) *world {
	t.Helper()

	dir, err := os.MkdirTemp("", "peard-recap-test-*")
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

	posts.Register(app)
	recap.Register(app)

	w := &world{app: app}
	w.alice, w.aliceTok = w.newUser(t, "alice@example.com")
	w.bob, w.bobTok = w.newUser(t, "bob@example.com")
	w.outsider, w.outsiderTok = w.newUser(t, "mallory@example.com")
	w.pair = w.newPair(t)
	w.addMember(t, w.alice)
	w.addMember(t, w.bob)

	router, err := apis.NewRouter(app)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}
	event := new(core.ServeEvent)
	event.App = app
	event.Router = router
	if err := app.OnServe().Trigger(event, func(e *core.ServeEvent) error {
		mux, err := e.Router.BuildMux()
		w.mux = mux
		return err
	}); err != nil {
		t.Fatalf("build mux: %v", err)
	}
	return w
}

// recap asks for the summary with an explicit UTC clock, so a test machine's
// own zone cannot move a day boundary under the assertions.
func (w *world) recap(t *testing.T, token string) response {
	t.Helper()
	from := time.Now().UTC().AddDate(0, 0, -6).Format("2006-01-02") + "T00:00:00Z"
	path := fmt.Sprintf("/api/peard/recap?pair=%s&tz=0&from=%s", w.pair.Id, from)
	status, body := w.do(t, path, token)
	if status != 200 {
		t.Fatalf("recap: %d %s", status, body)
	}
	var got response
	if err := json.Unmarshal([]byte(body), &got); err != nil {
		t.Fatalf("decode %s: %v", body, err)
	}
	return got
}

func (w *world) do(t *testing.T, path, token string) (int, string) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if token != "" {
		req.Header.Set("Authorization", token)
	}
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	return rec.Code, rec.Body.String()
}

// post writes an event moment `daysAgo` days back, in UTC.
func (w *world) post(t *testing.T, author *core.Record, kind string, daysAgo int) {
	t.Helper()
	w.write(t, author, "event", kind, daysAgo)
}

func (w *world) photo(t *testing.T, author *core.Record, daysAgo int) {
	t.Helper()
	w.write(t, author, "photo", "", daysAgo)
}

func (w *world) write(t *testing.T, author *core.Record, postType, kind string, daysAgo int) {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("posts")
	if err != nil {
		t.Fatalf("posts collection: %v", err)
	}
	r := core.NewRecord(col)
	r.Set("pair", w.pair.Id)
	r.Set("author", author.Id)
	r.Set("type", postType)
	r.Set("event_kind", kind)
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save post: %v", err)
	}
	if daysAgo > 0 {
		w.backdate(t, r, daysAgo)
	}
}

// backdate moves a post's `created` and `happened_at` into the past, at midday UTC so a test can
// never land either side of a boundary by accident.
//
// Raw SQL rather than record.Set: `created` is an AutodateField and ignores
// writes through the record API — setting it and saving is silently a no-op,
// which is a very quiet way for a test to stop testing anything.
func (w *world) backdate(t *testing.T, record *core.Record, daysAgo int) {
	t.Helper()
	now := time.Now().UTC().AddDate(0, 0, -daysAgo)
	want := time.Date(now.Year(), now.Month(), now.Day(), 12, 0, 0, 0, time.UTC).
		Format("2006-01-02 15:04:05.000Z")

	if _, err := w.app.DB().
		NewQuery("UPDATE {{posts}} SET [[created]] = {:t}, [[happened_at]] = {:t} WHERE [[id]] = {:id}").
		Bind(map[string]any{"t": want, "id": record.Id}).
		Execute(); err != nil {
		t.Fatalf("backdate: %v", err)
	}

	// A helper whose failure mode is "the test passes anyway" has to check its
	// own work.
	fresh, err := w.app.FindRecordById("posts", record.Id)
	if err != nil {
		t.Fatalf("re-read post: %v", err)
	}
	for _, field := range []string{"created", "happened_at"} {
		if got := fresh.GetDateTime(field); got.String() != want {
			t.Fatalf("backdate did not stick: %s is %s, want %s", field, got, want)
		}
	}
}

func (w *world) newUser(t *testing.T, email string) (*core.Record, string) {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("users collection: %v", err)
	}
	r := core.NewRecord(col)
	r.SetEmail(email)
	r.SetVerified(true)
	r.SetPassword("Password123!")
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save user %s: %v", email, err)
	}
	token, err := r.NewAuthToken()
	if err != nil {
		t.Fatalf("auth token %s: %v", email, err)
	}
	return r, token
}

func (w *world) newPair(t *testing.T) *core.Record {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("pairs")
	if err != nil {
		t.Fatalf("pairs collection: %v", err)
	}
	r := core.NewRecord(col)
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save pair: %v", err)
	}
	return r
}

func (w *world) addMember(t *testing.T, user *core.Record) {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("pair_members")
	if err != nil {
		t.Fatalf("pair_members collection: %v", err)
	}
	r := core.NewRecord(col)
	r.Set("pair", w.pair.Id)
	r.Set("user", user.Id)
	r.Set("role", "member")
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save membership: %v", err)
	}
}

// The window is about when moments happened. One logged today but set back
// before the window is outside it, whatever `created` says.
func TestTheWindowCountsWhenAMomentHappened(t *testing.T) {
	w := newWorld(t)
	w.post(t, w.alice, "coffee", 0)

	earlier := time.Now().UTC().AddDate(0, 0, -10).Format("2006-01-02 15:04:05.000Z")
	if _, err := w.app.DB().
		NewQuery("UPDATE {{posts}} SET [[happened_at]] = {:t}").
		Bind(map[string]any{"t": earlier}).
		Execute(); err != nil {
		t.Fatalf("move happened_at: %v", err)
	}

	if got := w.recap(t, w.aliceTok); got.Total != 0 {
		t.Errorf("total=%d, want 0 — it happened before the window", got.Total)
	}
}

// MARK: Water streaks (#323)

// A day counts only when everything logged that day adds up to the target.
func TestOnlyDaysThatMetTheTargetCountForWater(t *testing.T) {
	w := newWorld(t)
	w.water(t, w.alice, 2000, 0)
	w.water(t, w.alice, 2000, 1)
	w.water(t, w.alice, 1900, 2) // a hair short, so the run stops here
	w.water(t, w.alice, 2000, 3)

	got := w.recapWith(t, w.aliceTok, "")

	if got.WaterStreak.Current != 2 || got.WaterStreak.Best != 2 {
		t.Errorf("water streak = %d/%d, want 2/2", got.WaterStreak.Current, got.WaterStreak.Best)
	}
	if got.Streak.Current != 4 {
		t.Errorf("moment streak = %d, want the four days anybody logged", got.Streak.Current)
	}
}

// The connection's water is combined across people and across the day.
func TestWaterFromEverybodyAddsUpWithinADay(t *testing.T) {
	w := newWorld(t)
	w.water(t, w.alice, 900, 0)
	w.water(t, w.bob, 600, 0)
	w.water(t, w.alice, 500, 0)

	got := w.recapWith(t, w.aliceTok, "")

	if got.WaterStreak.Current != 1 {
		t.Errorf("water streak = %d, want 1 (900+600+500 reaches 2000)", got.WaterStreak.Current)
	}
}

// Moments with no amount, and other moments, add nothing.
func TestMomentsWithoutAnAmountDoNotCountTowardsWater(t *testing.T) {
	w := newWorld(t)
	w.post(t, w.alice, "coffee", 0)
	w.post(t, w.alice, "water", 0)
	w.photo(t, w.alice, 0)

	got := w.recapWith(t, w.aliceTok, "")

	if got.WaterStreak.Current != 0 || got.WaterStreak.Best != 0 {
		t.Errorf("water streak = %d/%d, want zeroes", got.WaterStreak.Current, got.WaterStreak.Best)
	}
}

// The caller's own target decides, since the server cannot see it.
func TestTheRequestsTargetDecidesWhatCounts(t *testing.T) {
	w := newWorld(t)
	w.water(t, w.alice, 1500, 0)
	w.water(t, w.alice, 1500, 1)

	if got := w.recapWith(t, w.aliceTok, "&water_target=1500"); got.WaterStreak.Current != 2 {
		t.Errorf("at 1500: water streak = %d, want 2", got.WaterStreak.Current)
	}
	if got := w.recapWith(t, w.aliceTok, "&water_target=3000"); got.WaterStreak.Current != 0 {
		t.Errorf("at 3000: water streak = %d, want 0", got.WaterStreak.Current)
	}
}

// Without a target the built-in 2000 ml applies; so it does for one that is not
// a number, which an older or confused client might send.
func TestAMissingOrGarbledTargetFallsBackToTheDefault(t *testing.T) {
	w := newWorld(t)
	w.water(t, w.alice, 2000, 0)
	w.water(t, w.alice, 1999, 1)

	for _, extra := range []string{"", "&water_target=", "&water_target=lots"} {
		got := w.recapWith(t, w.aliceTok, extra)
		if got.WaterStreak.Current != 1 || got.WaterStreak.Best != 1 {
			t.Errorf("%q: water streak = %d/%d, want 1/1 at the default", extra, got.WaterStreak.Current, got.WaterStreak.Best)
		}
	}
}

// A target of zero would be met by every day. It is no target, so no streak.
func TestAZeroTargetIsNoWaterStreakRatherThanAnEndlessOne(t *testing.T) {
	w := newWorld(t)
	w.water(t, w.alice, 2000, 0)
	w.water(t, w.alice, 2000, 1)

	for _, extra := range []string{"&water_target=0", "&water_target=-5"} {
		got := w.recapWith(t, w.aliceTok, extra)
		if got.WaterStreak.Current != 0 || got.WaterStreak.Best != 0 {
			t.Errorf("%q: water streak = %d/%d, want zeroes", extra, got.WaterStreak.Current, got.WaterStreak.Best)
		}
	}
}

// Today has not reached the target yet, which has not broken anything: the run
// reaches back from the most recent day that did.
func TestATodayShortOfTheTargetDoesNotBreakTheWaterStreak(t *testing.T) {
	w := newWorld(t)
	w.water(t, w.alice, 500, 0) // not there yet
	w.water(t, w.alice, 2000, 1)
	w.water(t, w.alice, 2000, 2)

	got := w.recapWith(t, w.aliceTok, "")

	if got.WaterStreak.Current != 2 {
		t.Errorf("water streak = %d, want 2 ending yesterday", got.WaterStreak.Current)
	}
}

// Once a whole day has passed without reaching it, the run is over, though the
// best is kept.
func TestAWaterStreakThatEndedIsNotCurrent(t *testing.T) {
	w := newWorld(t)
	w.water(t, w.alice, 2000, 2)
	w.water(t, w.alice, 2000, 3)
	w.water(t, w.alice, 2000, 4)

	got := w.recapWith(t, w.aliceTok, "")

	if got.WaterStreak.Current != 0 || got.WaterStreak.Best != 3 {
		t.Errorf("water streak = %d/%d, want 0/3", got.WaterStreak.Current, got.WaterStreak.Best)
	}
}

// A gap in the middle ends the run that follows it; the older one is the best.
func TestAShortDayInTheMiddleSplitsTheWaterStreak(t *testing.T) {
	w := newWorld(t)
	w.water(t, w.alice, 2000, 0)
	w.water(t, w.alice, 2000, 1)
	w.water(t, w.alice, 1000, 2)
	for day := 3; day < 7; day++ {
		w.water(t, w.alice, 2000, day)
	}

	got := w.recapWith(t, w.aliceTok, "")

	if got.WaterStreak.Current != 2 || got.WaterStreak.Best != 4 {
		t.Errorf("water streak = %d/%d, want 2/4", got.WaterStreak.Current, got.WaterStreak.Best)
	}
}

// Days are the caller's, as for the moment streak. Two moments at 23:30 and
// 00:30 UTC are one local day in UTC but two on opposite sides of a boundary
// in UTC+1, and which side decides whether the day reaches the target.
func TestWaterDaysFollowTheCallersClock(t *testing.T) {
	w := newWorld(t)
	// 23:30 UTC yesterday and 00:30 UTC today, 1000 ml each.
	w.waterAt(t, w.alice, 1000, -1, 23, 30)
	w.waterAt(t, w.alice, 1000, 0, 0, 30)

	if got := w.recapWith(t, w.aliceTok, ""); got.WaterStreak.Best != 0 {
		t.Errorf("UTC: best = %d, want 0 (1000 ml on each of two days)", got.WaterStreak.Best)
	}
	// Both fall on one local day at UTC+1 and sum to the target. The local
	// day is "today" there whenever the first is already the 0:30 of it.
	got := w.recapWith(t, w.aliceTok, "&tz=60")
	if got.WaterStreak.Best != 1 {
		t.Errorf("UTC+1: best = %d, want 1 (the two share a local day)", got.WaterStreak.Best)
	}
}

// Like the moment streak, water is only looked for within the horizon.
func TestAWaterStreakIsReadWithinTheHorizon(t *testing.T) {
	w := newWorld(t)
	for day := 0; day < 200; day++ {
		w.water(t, w.alice, 2000, day)
	}

	got := w.recapWith(t, w.aliceTok, "")

	if got.WaterStreak.Current < 179 || got.WaterStreak.Current > 181 {
		t.Errorf("water streak = %d, want about the 180-day horizon", got.WaterStreak.Current)
	}
	if got.WaterStreak.Best != got.WaterStreak.Current {
		t.Errorf("best = %d, want it equal to current %d", got.WaterStreak.Best, got.WaterStreak.Current)
	}
}

// A connection nobody has logged in answers with zeroes, as it does for the moment streak.
func TestAnEmptyConnectionHasNoWaterStreak(t *testing.T) {
	w := newWorld(t)

	got := w.recapWith(t, w.aliceTok, "")

	if got.WaterStreak.Current != 0 || got.WaterStreak.Best != 0 {
		t.Errorf("water streak = %d/%d, want zeroes", got.WaterStreak.Current, got.WaterStreak.Best)
	}
}

// recapWith is recap with extra query parameters appended.
func (w *world) recapWith(t *testing.T, token, extra string) response {
	t.Helper()
	from := time.Now().UTC().AddDate(0, 0, -6).Format("2006-01-02") + "T00:00:00Z"
	path := fmt.Sprintf("/api/peard/recap?pair=%s&from=%s%s", w.pair.Id, from, extra)
	if !strings.Contains(extra, "tz=") {
		path += "&tz=0"
	}
	status, body := w.do(t, path, token)
	if status != 200 {
		t.Fatalf("recap: %d %s", status, body)
	}
	var got response
	if err := json.Unmarshal([]byte(body), &got); err != nil {
		t.Fatalf("decode %s: %v", body, err)
	}
	return got
}

// water logs `ml` of water `daysAgo` days back, at midday UTC.
func (w *world) water(t *testing.T, author *core.Record, ml, daysAgo int) {
	t.Helper()
	w.waterAt(t, author, ml, -daysAgo, 12, 0)
}

// waterAt logs water on the UTC day `offset` days from today (negative is the
// past), at the given UTC hour and minute.
func (w *world) waterAt(t *testing.T, author *core.Record, ml, offset, hour, minute int) {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("posts")
	if err != nil {
		t.Fatalf("posts collection: %v", err)
	}
	r := core.NewRecord(col)
	r.Set("pair", w.pair.Id)
	r.Set("author", author.Id)
	r.Set("type", "event")
	r.Set("event_kind", "water")
	r.Set("amount", ml)
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save water: %v", err)
	}
	day := time.Now().UTC().AddDate(0, 0, offset)
	want := time.Date(day.Year(), day.Month(), day.Day(), hour, minute, 0, 0, time.UTC).
		Format("2006-01-02 15:04:05.000Z")
	if _, err := w.app.DB().
		NewQuery("UPDATE {{posts}} SET [[created]] = {:t}, [[happened_at]] = {:t} WHERE [[id]] = {:id}").
		Bind(map[string]any{"t": want, "id": r.Id}).Execute(); err != nil {
		t.Fatalf("backdate: %v", err)
	}
}

// MARK: Per-person targets (#335)

// A stored target decides what counts, for everybody in the connection alike:
// the streak is the connection's, so it cannot depend on who is asking.
func TestAStoredTargetDrivesTheWaterStreak(t *testing.T) {
	w := newWorld(t)
	w.setTarget(t, w.alice, 1000, 1500)
	w.setTarget(t, w.bob, 1000, 1500)
	w.water(t, w.alice, 1500, 0)
	w.water(t, w.bob, 1500, 0) // 3000 together: meets 1500+1500
	w.water(t, w.alice, 1500, 1)
	w.water(t, w.bob, 1000, 1) // 2500 together: short of 3000

	for name, token := range map[string]string{"alice": w.aliceTok, "bob": w.bobTok} {
		got := w.recapWith(t, token, "")
		if got.WaterStreak.Current != 1 || got.WaterStreak.Best != 1 {
			t.Errorf("%s: water streak = %d/%d, want 1/1 against the stored 3000", name, got.WaterStreak.Current, got.WaterStreak.Best)
		}
	}
}

// The stored target wins over the one an app sends: the app's is a fallback.
func TestAStoredTargetBeatsTheQueryParam(t *testing.T) {
	w := newWorld(t)
	w.setTarget(t, w.alice, 500, 800)
	w.setTarget(t, w.bob, 500, 800)
	w.water(t, w.alice, 1600, 0)

	if got := w.recapWith(t, w.aliceTok, "&water_target=9999"); got.WaterStreak.Current != 1 {
		t.Errorf("water streak = %d, want 1: 1600 reaches the stored 800+800, not the param", got.WaterStreak.Current)
	}
}

// Somebody who stored nothing counts at the fallback, so one person setting a
// goal does not silently halve the connection's.
func TestAMemberWithNoTargetCountsAtTheFallback(t *testing.T) {
	w := newWorld(t)
	w.setTarget(t, w.alice, 1000, 1500)
	w.water(t, w.alice, 3400, 0) // 1500 + the default 2000 = 3500: just short
	w.water(t, w.alice, 3500, 1) // exactly enough

	got := w.recapWith(t, w.aliceTok, "")

	if got.WaterStreak.Current != 1 {
		t.Errorf("water streak = %d, want 1 (yesterday met 3500, today did not)", got.WaterStreak.Current)
	}
	if got := w.recapWith(t, w.aliceTok, "&water_target=1000"); got.WaterStreak.Current != 2 {
		t.Errorf("with a 1000 fallback: water streak = %d, want 2 (1500+1000 = 2500)", got.WaterStreak.Current)
	}
}

// Nobody has stored anything — every connection before this change — so the
// request's number is the target exactly as it always was, unsummed.
func TestWithNoStoredTargetsTheParamStillDecides(t *testing.T) {
	w := newWorld(t)
	w.water(t, w.alice, 1500, 0)
	w.water(t, w.alice, 1500, 1)

	if got := w.recapWith(t, w.aliceTok, "&water_target=1500"); got.WaterStreak.Current != 2 {
		t.Errorf("at 1500: water streak = %d, want 2", got.WaterStreak.Current)
	}
	if got := w.recapWith(t, w.aliceTok, "&water_target=3000"); got.WaterStreak.Current != 0 {
		t.Errorf("at 3000: water streak = %d, want 0", got.WaterStreak.Current)
	}
	if got := w.recapWith(t, w.aliceTok, ""); got.WaterStreak.Current != 0 {
		t.Errorf("at the 2000 default: water streak = %d, want 0 (1500 a day is short)", got.WaterStreak.Current)
	}
}

// Both people see both goals, whoever asks.
func TestTheRecapCarriesEveryMembersTarget(t *testing.T) {
	w := newWorld(t)
	w.setTarget(t, w.alice, 1200, 2500)

	for name, token := range map[string]string{"alice": w.aliceTok, "bob": w.bobTok} {
		got := w.recapWith(t, token, "")
		byUser := map[string][2]int{}
		for _, tgt := range got.WaterTargets {
			byUser[tgt.User] = [2]int{tgt.Minimum, tgt.Recommended}
		}
		if len(got.WaterTargets) != 2 {
			t.Fatalf("%s: %d targets, want one per member", name, len(got.WaterTargets))
		}
		if byUser[w.alice.Id] != [2]int{1200, 2500} {
			t.Errorf("%s sees alice's target as %v, want [1200 2500]", name, byUser[w.alice.Id])
		}
		if byUser[w.bob.Id] != [2]int{0, 0} {
			t.Errorf("%s sees bob's target as %v, want [0 0] (none stored)", name, byUser[w.bob.Id])
		}
	}
}

// MARK: Writing a target

func TestAMemberSetsTheirOwnTargetOnly(t *testing.T) {
	w := newWorld(t)

	status, body := w.postTarget(t, w.aliceTok, w.pair.Id, 1000, 3000)
	if status != http.StatusOK {
		t.Fatalf("set target = %d %s, want 200", status, body)
	}

	if min, rec := w.stored(t, w.alice); min != 1000 || rec != 3000 {
		t.Errorf("alice stored %d/%d, want 1000/3000", min, rec)
	}
	if min, rec := w.stored(t, w.bob); min != 0 || rec != 0 {
		t.Errorf("bob stored %d/%d, want untouched 0/0", min, rec)
	}
}

func TestSettingATargetTwiceKeepsTheLatest(t *testing.T) {
	w := newWorld(t)
	w.postTarget(t, w.bobTok, w.pair.Id, 1000, 3000)

	if status, body := w.postTarget(t, w.bobTok, w.pair.Id, 800, 1800); status != http.StatusOK {
		t.Fatalf("second set = %d %s", status, body)
	}

	if min, rec := w.stored(t, w.bob); min != 800 || rec != 1800 {
		t.Errorf("bob stored %d/%d, want 800/1800", min, rec)
	}
}

func TestZeroClearsATarget(t *testing.T) {
	w := newWorld(t)
	w.setTarget(t, w.alice, 1000, 3000)

	if status, body := w.postTarget(t, w.aliceTok, w.pair.Id, 0, 0); status != http.StatusOK {
		t.Fatalf("clear = %d %s", status, body)
	}

	if min, rec := w.stored(t, w.alice); min != 0 || rec != 0 {
		t.Errorf("alice stored %d/%d, want cleared", min, rec)
	}
}

func TestANonMemberCannotSetATarget(t *testing.T) {
	w := newWorld(t)

	status, _ := w.postTarget(t, w.outsiderTok, w.pair.Id, 1000, 3000)

	if status != http.StatusForbidden {
		t.Errorf("outsider set target = %d, want 403", status)
	}
	for _, u := range []*core.Record{w.alice, w.bob} {
		if min, rec := w.stored(t, u); min != 0 || rec != 0 {
			t.Errorf("%s stored %d/%d after an outsider's write", u.Id, min, rec)
		}
	}
}

func TestATargetNeedsASession(t *testing.T) {
	w := newWorld(t)

	if status, _ := w.postTarget(t, "", w.pair.Id, 1000, 3000); status != http.StatusUnauthorized {
		t.Errorf("anonymous set target = %d, want 401", status)
	}
}

func TestNonsenseTargetsAreRefused(t *testing.T) {
	w := newWorld(t)
	cases := map[string][2]int{
		"negative minimum":     {-1, 2000},
		"negative goal":        {0, -5},
		"minimum above goal":   {2500, 2000},
		"minimum without goal": {500, 0},
		"goal above ceiling":   {1000, 5001},
	}
	for name, c := range cases {
		if status, _ := w.postTarget(t, w.aliceTok, w.pair.Id, c[0], c[1]); status != http.StatusBadRequest {
			t.Errorf("%s: status %d, want 400", name, status)
		}
	}
	if min, rec := w.stored(t, w.alice); min != 0 || rec != 0 {
		t.Errorf("alice stored %d/%d after refused writes", min, rec)
	}
}

func TestATargetNeedsAPair(t *testing.T) {
	w := newWorld(t)

	if status, _ := w.postTarget(t, w.aliceTok, "", 1000, 2000); status != http.StatusBadRequest {
		t.Errorf("no pair = %d, want 400", status)
	}
}

// setTarget stores a member's target directly, as a prior write would have.
func (w *world) setTarget(t *testing.T, user *core.Record, minimum, recommended int) {
	t.Helper()
	rec := w.membership(t, user)
	rec.Set("water_minimum", minimum)
	rec.Set("water_recommended", recommended)
	if err := w.app.Save(rec); err != nil {
		t.Fatalf("save target: %v", err)
	}
}

func (w *world) membership(t *testing.T, user *core.Record) *core.Record {
	t.Helper()
	rec, err := w.app.FindFirstRecordByFilter("pair_members", "pair = {:pair} && user = {:user}",
		map[string]any{"pair": w.pair.Id, "user": user.Id})
	if err != nil {
		t.Fatalf("find membership: %v", err)
	}
	return rec
}

func (w *world) stored(t *testing.T, user *core.Record) (minimum, recommended int) {
	t.Helper()
	rec := w.membership(t, user)
	return rec.GetInt("water_minimum"), rec.GetInt("water_recommended")
}

func (w *world) postTarget(t *testing.T, token, pair string, minimum, recommended int) (int, string) {
	t.Helper()
	payload := fmt.Sprintf(`{"pair":%q,"minimum":%d,"recommended":%d}`, pair, minimum, recommended)
	req := httptest.NewRequest(http.MethodPost, "/api/peard/water/target", strings.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", token)
	}
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	return rec.Code, rec.Body.String()
}
