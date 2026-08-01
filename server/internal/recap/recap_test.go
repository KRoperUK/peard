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
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

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

// backdate moves a post's `created` into the past, at midday UTC so a test can
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
		NewQuery("UPDATE {{posts}} SET [[created]] = {:t} WHERE [[id]] = {:id}").
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
	if got := fresh.GetDateTime("created"); got.String() != want {
		t.Fatalf("backdate did not stick: created is %s, want %s", got, want)
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
