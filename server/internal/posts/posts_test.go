// Package posts_test is external to `posts` on purpose: these tests need the
// real Pear'd schema, which comes from blank-importing `peard/migrations`, and
// that package imports the route packages. An in-package test file would make
// that an import cycle.
package posts_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
	"github.com/pocketbase/pocketbase/tools/types"

	"peard/internal/posts"

	_ "peard/migrations"
)

// A connection with two people in it, one moment each, so every check has both
// "mine" and "somebody else's" to hand.
type world struct {
	app *tests.TestApp
	mux http.Handler

	alice, bob       *core.Record
	aliceTok, bobTok string
	pair             *core.Record
	alicePost        *core.Record
	bobPost          *core.Record
	alicePhoto       *core.Record
}

func newWorld(t *testing.T) *world {
	t.Helper()

	dir, err := os.MkdirTemp("", "peard-posts-test-*")
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

	w := &world{app: app}
	w.alice, w.aliceTok = w.newUser(t, "alice@example.com")
	w.bob, w.bobTok = w.newUser(t, "bob@example.com")
	w.pair = w.newPair(t)
	w.addMember(t, w.alice)
	w.addMember(t, w.bob)
	w.alicePost = w.newEvent(t, w.alice, "beer", "at the pub")
	w.bobPost = w.newEvent(t, w.bob, "coffee", "")
	w.alicePhoto = w.newPhoto(t, w.alice)

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

// MARK: The edit itself

func TestAnAuthorCanRewriteTheirOwnNote(t *testing.T) {
	w := newWorld(t)

	status, body := w.edit(t, w.aliceTok, `{"post":"`+w.alicePost.Id+`","note":"at the other pub"}`)
	if status != 200 {
		t.Fatalf("edit: %d %s", status, body)
	}
	if got := w.reload(t, w.alicePost.Id).GetString("note"); got != "at the other pub" {
		t.Errorf("note = %q, want the new one", got)
	}
}

// Taking the words back is an edit like any other. Sent as an empty string
// rather than omitted, which is exactly the distinction the handler's pointers
// exist to preserve — omitted means "leave it alone".
func TestANoteCanBeCleared(t *testing.T) {
	w := newWorld(t)

	status, body := w.edit(t, w.aliceTok, `{"post":"`+w.alicePost.Id+`","note":""}`)
	if status != 200 {
		t.Fatalf("edit: %d %s", status, body)
	}
	if got := w.reload(t, w.alicePost.Id).GetString("note"); got != "" {
		t.Errorf("note = %q, want it gone", got)
	}
}

func TestAMomentCanBecomeADifferentMoment(t *testing.T) {
	w := newWorld(t)

	status, body := w.edit(t, w.aliceTok, `{"post":"`+w.alicePost.Id+`","event_kind":"coffee"}`)
	if status != 200 {
		t.Fatalf("edit: %d %s", status, body)
	}
	got := w.reload(t, w.alicePost.Id)
	if got.GetString("event_kind") != "coffee" {
		t.Errorf("event_kind = %q, want coffee", got.GetString("event_kind"))
	}
	if got.GetString("note") != "at the pub" {
		t.Errorf("note = %q — a kind change must not touch the note", got.GetString("note"))
	}
}

// The field the client reads to decide whether to say "edited".
//
// The post is backdated first rather than the test trusting real time to pass:
// PocketBase stamps to the millisecond, and creating a post and editing it land
// in the same tick often enough that this failed one run in eight before the
// backdate went in.
func TestAnEditMovesTheUpdatedStamp(t *testing.T) {
	w := newWorld(t)
	w.backdate(t, w.alicePost, time.Hour)
	before := w.reload(t, w.alicePost.Id).GetDateTime("updated")

	if status, body := w.edit(t, w.aliceTok, `{"post":"`+w.alicePost.Id+`","note":"later"}`); status != 200 {
		t.Fatalf("edit: %d %s", status, body)
	}

	after := w.reload(t, w.alicePost.Id).GetDateTime("updated")
	if !after.Time().After(before.Time()) {
		t.Errorf("updated did not move: %s then %s", before, after)
	}
}

// An untouched moment must *not* look edited, or the label means nothing. Both
// stamps are written together here, exactly as a create does.
func TestAnUntouchedMomentDoesNotLookEdited(t *testing.T) {
	w := newWorld(t)
	w.backdate(t, w.alicePost, time.Hour)

	got := w.reload(t, w.alicePost.Id)
	if got.GetDateTime("updated").String() != got.GetDateTime("created").String() {
		t.Errorf("created %s but updated %s", got.GetDateTime("created"), got.GetDateTime("updated"))
	}
}

// MARK: Who may

func TestSomebodyElsesMomentCannotBeEdited(t *testing.T) {
	w := newWorld(t)

	status, body := w.edit(t, w.bobTok, `{"post":"`+w.alicePost.Id+`","note":"bob was here"}`)
	if status != 403 {
		t.Fatalf("edit somebody else's: %d %s", status, body)
	}
	if got := w.reload(t, w.alicePost.Id).GetString("note"); got != "at the pub" {
		t.Errorf("note = %q — sharing a connection is not authority over what somebody said", got)
	}
}

func TestEditingNeedsASession(t *testing.T) {
	w := newWorld(t)

	status, _ := w.edit(t, "", `{"post":"`+w.alicePost.Id+`","note":"anyone?"}`)
	if status != 401 {
		t.Fatalf("unauthenticated edit = %d, want 401", status)
	}
}

// MARK: What may

// A photo has no moment kind. Giving it one would put a moment in the tallies
// that nobody logged.
func TestAPhotoHasNoKindToChange(t *testing.T) {
	w := newWorld(t)

	status, body := w.edit(t, w.aliceTok, `{"post":"`+w.alicePhoto.Id+`","event_kind":"beer"}`)
	if status != 400 {
		t.Fatalf("kind on a photo: %d %s", status, body)
	}
	if got := w.reload(t, w.alicePhoto.Id).GetString("event_kind"); got != "" {
		t.Errorf("event_kind = %q, want it left empty", got)
	}
}

// A photo's note is its caption, and that is ordinary text somebody may want
// back.
func TestAPhotoCaptionCanStillBeEdited(t *testing.T) {
	w := newWorld(t)

	status, body := w.edit(t, w.aliceTok, `{"post":"`+w.alicePhoto.Id+`","note":"the dog, finally still"}`)
	if status != 200 {
		t.Fatalf("edit photo note: %d %s", status, body)
	}
	if got := w.reload(t, w.alicePhoto.Id).GetString("note"); got != "the dog, finally still" {
		t.Errorf("note = %q", got)
	}
}

func TestAMomentCannotLoseItsKindAltogether(t *testing.T) {
	w := newWorld(t)

	status, body := w.edit(t, w.aliceTok, `{"post":"`+w.alicePost.Id+`","event_kind":"   "}`)
	if status != 400 {
		t.Fatalf("blank kind: %d %s", status, body)
	}
	if got := w.reload(t, w.alicePost.Id).GetString("event_kind"); got != "beer" {
		t.Errorf("event_kind = %q, want it untouched", got)
	}
}

func TestAnOverLongNoteIsRefused(t *testing.T) {
	w := newWorld(t)
	long := string(bytes.Repeat([]byte("a"), 281))

	status, body := w.edit(t, w.aliceTok, `{"post":"`+w.alicePost.Id+`","note":"`+long+`"}`)
	if status != 400 {
		t.Fatalf("over-long note: %d %s", status, body)
	}
	if got := w.reload(t, w.alicePost.Id).GetString("note"); got != "at the pub" {
		t.Errorf("note = %q, want it untouched", got)
	}
}

// The route writes two fields and nothing else. This is the whole reason it
// exists rather than an UpdateRule, which cannot say which fields may change:
// an author could otherwise move their moment into another connection, or hand
// it to somebody who never logged it.
func TestNothingElseAboutAMomentCanBeChanged(t *testing.T) {
	w := newWorld(t)
	other := w.newPair(t)

	body := `{"post":"` + w.alicePost.Id + `","note":"fine","pair":"` + other.Id +
		`","author":"` + w.bob.Id + `","type":"photo"}`
	if status, resp := w.edit(t, w.aliceTok, body); status != 200 {
		t.Fatalf("edit: %d %s", status, resp)
	}

	got := w.reload(t, w.alicePost.Id)
	if got.GetString("pair") != w.pair.Id {
		t.Errorf("pair = %q — a moment must not be movable between connections", got.GetString("pair"))
	}
	if got.GetString("author") != w.alice.Id {
		t.Errorf("author = %q — a moment must not be reassignable", got.GetString("author"))
	}
	if got.GetString("type") != "event" {
		t.Errorf("type = %q — an event must not become a photo", got.GetString("type"))
	}
}

func TestAnEmptyEditIsRefused(t *testing.T) {
	w := newWorld(t)

	if status, body := w.edit(t, w.aliceTok, `{"post":"`+w.alicePost.Id+`"}`); status != 400 {
		t.Fatalf("empty edit: %d %s", status, body)
	}
}

func TestEditingSomethingThatIsGoneSaysSo(t *testing.T) {
	w := newWorld(t)

	status, body := w.edit(t, w.aliceTok, `{"post":"nosuchpostid00","note":"hello"}`)
	if status != 404 {
		t.Fatalf("missing post: %d %s", status, body)
	}
	var res struct {
		Message string `json:"message"`
	}
	_ = json.Unmarshal([]byte(body), &res)
	if res.Message == "" {
		t.Error("a 404 here needs a message somebody can read")
	}
}

// MARK: Deletion, which is the collection rule rather than a route

// Asserted here because the app now offers a delete button that depends on it,
// and a rule with nothing exercising it is a rule that can quietly change.
func TestAnAuthorCanDeleteTheirOwnMoment(t *testing.T) {
	w := newWorld(t)

	status, body := w.do(t, http.MethodDelete, "/api/collections/posts/records/"+w.alicePost.Id, w.aliceTok, "")
	if status != 204 {
		t.Fatalf("delete own: %d %s", status, body)
	}
	if _, err := w.app.FindRecordById("posts", w.alicePost.Id); err == nil {
		t.Error("the moment is still there")
	}
}

func TestSomebodyElsesMomentCannotBeDeleted(t *testing.T) {
	w := newWorld(t)

	status, body := w.do(t, http.MethodDelete, "/api/collections/posts/records/"+w.alicePost.Id, w.bobTok, "")
	if status == 204 {
		t.Fatalf("bob deleted alice's moment: %d %s", status, body)
	}
	if _, err := w.app.FindRecordById("posts", w.alicePost.Id); err != nil {
		t.Error("alice's moment went anyway")
	}
}

// MARK: Helpers

func (w *world) edit(t *testing.T, token, body string) (int, string) {
	t.Helper()
	return w.do(t, http.MethodPost, "/api/peard/posts/edit", token, body)
}

func (w *world) do(t *testing.T, method, path, token, body string) (int, string) {
	t.Helper()
	req := httptest.NewRequest(method, path, bytes.NewReader([]byte(body)))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", token)
	}
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	return rec.Code, rec.Body.String()
}

// backdate moves a post's timestamps into the past, both together, the way a
// create writes them.
//
// Raw SQL rather than record.Set: `created` and `updated` are AutodateFields,
// and they ignore writes through the record API — setting one and saving is
// silently a no-op, which is a very quiet way for a test to stop testing
// anything. Same reason as `backdate` in the pairs read-state tests.
func (w *world) backdate(t *testing.T, record *core.Record, by time.Duration) {
	t.Helper()
	want := types.NowDateTime().Add(-by)
	_, err := w.app.DB().
		NewQuery("UPDATE {{posts}} SET [[created]] = {:t}, [[updated]] = {:t} WHERE [[id]] = {:id}").
		Bind(map[string]any{"t": want.String(), "id": record.Id}).
		Execute()
	if err != nil {
		t.Fatalf("backdate post %s: %v", record.Id, err)
	}

	// A helper whose failure mode is "the test passes anyway" has to check its
	// own work.
	fresh := w.reload(t, record.Id)
	if got := fresh.GetDateTime("updated"); got.String() != want.String() {
		t.Fatalf("backdate did not stick: updated is %s, want %s", got, want)
	}
}

func (w *world) reload(t *testing.T, id string) *core.Record {
	t.Helper()
	r, err := w.app.FindRecordById("posts", id)
	if err != nil {
		t.Fatalf("reload post %s: %v", id, err)
	}
	return r
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

func (w *world) newEvent(t *testing.T, author *core.Record, kind, note string) *core.Record {
	t.Helper()
	return w.newPost(t, author, "event", kind, note)
}

func (w *world) newPhoto(t *testing.T, author *core.Record) *core.Record {
	t.Helper()
	return w.newPost(t, author, "photo", "", "")
}

func (w *world) newPost(t *testing.T, author *core.Record, kind, eventKind, note string) *core.Record {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("posts")
	if err != nil {
		t.Fatalf("posts collection: %v", err)
	}
	r := core.NewRecord(col)
	r.Set("pair", w.pair.Id)
	r.Set("author", author.Id)
	r.Set("type", kind)
	r.Set("event_kind", eventKind)
	r.Set("note", note)
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save post: %v", err)
	}
	return r
}
