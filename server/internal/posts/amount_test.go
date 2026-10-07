package posts_test

import (
	"encoding/json"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"

	"peard/internal/tallies"
)

// MARK: A moment that carries an amount

// Water is an ordinary moment with a number on it, so the number goes through
// the same collection endpoint as everything else.
func TestAWaterMomentCarriesItsAmount(t *testing.T) {
	w := newWorld(t)

	post := w.create(t, w.aliceTok, `,"event_kind":"water","amount":330`)

	if got := post.GetInt("amount"); got != 330 {
		t.Errorf("amount = %d, want 330", got)
	}
	if got := post.GetString("event_kind"); got != "water" {
		t.Errorf("event_kind = %q, want water", got)
	}
}

// The app's `PendingSend.postFields` is a [String: String], so the amount arrives
// as "500" rather than 500. It has to land as a number all the same.
func TestAnAmountSentAsAStringStillLandsAsANumber(t *testing.T) {
	w := newWorld(t)

	post := w.create(t, w.aliceTok, `,"event_kind":"water","amount":"500"`)

	if got := post.GetInt("amount"); got != 500 {
		t.Errorf("amount = %d, want 500", got)
	}
}

// Every moment that is not measured carries none, and says so by being zero —
// the way PocketBase stores a number nobody gave.
func TestAMomentWithoutAnAmountCarriesNone(t *testing.T) {
	w := newWorld(t)

	beer := w.create(t, w.aliceTok, "")
	photo := w.create(t, w.aliceTok, `,"type":"photo","event_kind":""`)

	for name, post := range map[string]*core.Record{"beer": beer, "photo": photo, "seeded": w.alicePost} {
		if got := post.GetInt("amount"); got != 0 {
			t.Errorf("%s amount = %d, want none", name, got)
		}
	}
}

func TestTheAmountIsInTheRecordTheTimelineReads(t *testing.T) {
	w := newWorld(t)
	post := w.create(t, w.aliceTok, `,"event_kind":"water","amount":330`)

	status, body := w.do(t, http.MethodGet, "/api/collections/posts/records/"+post.Id, w.bobTok, "")
	if status != http.StatusOK {
		t.Fatalf("read: %d %s", status, body)
	}
	var out struct {
		Amount float64 `json:"amount"`
	}
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.Amount != 330 {
		t.Errorf("amount over the wire = %v, want 330", out.Amount)
	}
}

// MARK: What is refused

func TestAnAmountCannotBeNegative(t *testing.T) {
	w := newWorld(t)

	status, body := w.createRaw(t, w.aliceTok, `,"event_kind":"water","amount":-250`)

	if status != http.StatusBadRequest {
		t.Errorf("status = %d %s, want 400", status, body)
	}
}

func TestAnAmountHasACeiling(t *testing.T) {
	w := newWorld(t)

	if status, body := w.createRaw(t, w.aliceTok, `,"event_kind":"water","amount":5000`); status != http.StatusOK {
		t.Errorf("5000 ml: %d %s, want it accepted", status, body)
	}
	if status, body := w.createRaw(t, w.aliceTok, `,"event_kind":"water","amount":5001`); status != http.StatusBadRequest {
		t.Errorf("5001 ml: %d %s, want 400", status, body)
	}
}

func TestAnAmountIsAWholeNumberOfMillilitres(t *testing.T) {
	w := newWorld(t)

	status, body := w.createRaw(t, w.aliceTok, `,"event_kind":"water","amount":330.5`)

	if status != http.StatusBadRequest {
		t.Errorf("status = %d %s, want 400", status, body)
	}
}

// An amount counts towards a day's total, and only moments count in totals.
func TestOnlyAMomentCanCarryAnAmount(t *testing.T) {
	w := newWorld(t)

	for _, extra := range []string{
		`,"type":"photo","event_kind":"","amount":330`,
		`,"type":"note","event_kind":"","note":"hi","amount":330`,
	} {
		if status, body := w.createRaw(t, w.aliceTok, extra); status != http.StatusBadRequest {
			t.Errorf("%s: %d %s, want 400", extra, status, body)
		}
	}
}

// MARK: The day's total

type tallyKind struct {
	Kind string `json:"kind"`
	Mine struct {
		DayAmount int `json:"day_amount"`
	}
	Others struct {
		DayAmount int `json:"day_amount"`
	}
}

func (w *world) waterTally(t *testing.T) tallyKind {
	t.Helper()
	status, body := w.do(t, http.MethodGet, "/api/peard/tallies?pair="+w.pair.Id+"&day="+url.QueryEscape(startOfToday()), w.aliceTok, "")
	if status != http.StatusOK {
		t.Fatalf("tallies: %d %s", status, body)
	}
	var out struct {
		Kinds []tallyKind `json:"kinds"`
	}
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		t.Fatalf("decode tallies: %v", err)
	}
	for _, k := range out.Kinds {
		if k.Kind == "water" {
			return k
		}
	}
	t.Fatalf("no water in tallies: %s", body)
	return tallyKind{}
}

func startOfToday() string {
	now := time.Now().UTC()
	return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC).Format(time.RFC3339)
}

// Today's millilitres are summed per side, so the client can add them up for the
// connection; and a glass logged before today is in no total for it.
func TestTheTalliesSumTodaysAmountPerSide(t *testing.T) {
	w := newWorld(t, tallies.Register)

	w.create(t, w.aliceTok, `,"event_kind":"water","amount":330`)
	w.create(t, w.aliceTok, `,"event_kind":"water","amount":500`)
	w.create(t, w.bobTok, `,"author":"`+w.bob.Id+`","event_kind":"water","amount":250`)
	old := w.create(t, w.aliceTok, `,"event_kind":"water","amount":1000`)
	w.backdateHappenedAt(t, old, 48*time.Hour)

	got := w.waterTally(t)

	if got.Mine.DayAmount != 830 {
		t.Errorf("mine day_amount = %d, want 830", got.Mine.DayAmount)
	}
	if got.Others.DayAmount != 250 {
		t.Errorf("others day_amount = %d, want 250", got.Others.DayAmount)
	}
}

func (w *world) backdateHappenedAt(t *testing.T, record *core.Record, by time.Duration) {
	t.Helper()
	at := record.GetDateTime("happened_at").Time().Add(-by).UTC().Format("2006-01-02 15:04:05.000Z")
	if _, err := w.app.DB().
		NewQuery("UPDATE {{posts}} SET [[happened_at]] = {:t} WHERE [[id]] = {:id}").
		Bind(map[string]any{"t": at, "id": record.Id}).
		Execute(); err != nil {
		t.Fatalf("backdate happened_at: %v", err)
	}
}
