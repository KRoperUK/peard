package widget_test

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// logMoment posts to the widget's moment route and returns the status and the
// created post's id.
func (w *feedWorld) logMoment(t *testing.T, fields map[string]any) (int, string) {
	t.Helper()
	fields["token"] = w.token
	fields["pair"] = w.pair.Id
	fields["kind"] = "beer"
	body, _ := json.Marshal(fields)
	req := httptest.NewRequest("POST", "/api/peard/widget/moment", strings.NewReader(string(body)))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	var parsed struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &parsed)
	return rec.Code, parsed.ID
}

// The watch queues a moment it could not send and sends it later with the time
// it was tapped (issue #286). It is stored as then, and not marked rewound:
// nobody picked the time, the moment arrived late.
func TestALateMomentKeepsTheTimeItHappened(t *testing.T) {
	w := newFeedWorld(t)
	tapped := time.Now().Add(-10 * time.Minute).UTC()

	code, id := w.logMoment(t, map[string]any{"happened_at": tapped.Format(time.RFC3339)})
	if code != 200 {
		t.Fatalf("status = %d, want 200", code)
	}
	post, err := w.app.FindRecordById("posts", id)
	if err != nil {
		t.Fatalf("find post: %v", err)
	}
	if got := post.GetDateTime("happened_at").Time(); got.Sub(tapped).Abs() > time.Second {
		t.Errorf("happened_at = %v, want %v", got, tapped)
	}
	if post.GetBool("rewound") {
		t.Errorf("a moment that arrived late is not a rewind")
	}
}

// The same limits as creating a post directly.
func TestALateMomentOutsideTheRewindWindowIsRefused(t *testing.T) {
	w := newFeedWorld(t)
	for name, at := range map[string]string{
		"more than a day back": time.Now().Add(-25 * time.Hour).UTC().Format(time.RFC3339),
		"in the future":        time.Now().Add(time.Hour).UTC().Format(time.RFC3339),
		"not a date":           "yesterday-ish",
	} {
		if code, _ := w.logMoment(t, map[string]any{"happened_at": at}); code != 400 {
			t.Errorf("%s: status = %d, want 400", name, code)
		}
	}
}
