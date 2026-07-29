package access

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
	"github.com/pocketbase/pocketbase/tools/filesystem"

	"peard/internal/avatars"
	"peard/internal/pairs"
	"peard/internal/profile"
	"peard/internal/tallies"

	_ "peard/migrations"
)

// The world these tests run in:
//
//	Connection "Flatmates"        Connection "Strangers"
//	  alice (owner)                 mallory (owner)
//	  bob   (member)
//
// alice and bob share a connection. mallory shares nothing with either, so every
// route and every collection must treat her as unable to see them — while still
// letting bob see alice, or the app would have nothing to draw.
//
// mallory is in a connection of her own rather than in none, deliberately: a
// user with no membership at all can be refused by an accident of the query
// (`FindRecordsByFilter` returning zero rows short-circuits a loop) rather than
// by the rule under test. Giving her a connection means every negative result
// below had to survive a code path that did find *something*.
const (
	alicePassword = "Password123!"
	onePixelPNG   = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
)

type world struct {
	app *tests.TestApp
	mux http.Handler

	alice, bob, mallory      *core.Record
	aliceTok, bobTok, malTok string
	flatmates, strangers     *core.Record
	alicePost                *core.Record
	aliceReaction            *core.Record
	aliceKind                *core.Record
	aliceAvatar              string
	bobMembership            *core.Record
}

func newWorld(t *testing.T) *world {
	t.Helper()

	dir, err := os.MkdirTemp("", "peard-access-test-*")
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

	// Every route that could plausibly disclose somebody else's information.
	pairs.Register(app)
	profile.Register(app)
	avatars.Register(app)
	tallies.Register(app)

	w := &world{app: app}
	w.seed(t)

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

func (w *world) seed(t *testing.T) {
	t.Helper()

	usersCol, err := w.app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("users collection: %v", err)
	}
	newUser := func(email, display string) (*core.Record, string) {
		r := core.NewRecord(usersCol)
		r.SetEmail(email)
		r.SetVerified(true)
		r.SetPassword(alicePassword)
		r.Set("display_name", display)
		if err := w.app.Save(r); err != nil {
			t.Fatalf("save user %s: %v", email, err)
		}
		token, err := r.NewAuthToken()
		if err != nil {
			t.Fatalf("auth token %s: %v", email, err)
		}
		return r, token
	}
	w.alice, w.aliceTok = newUser("alice@example.com", "Alice Anderson")
	w.bob, w.bobTok = newUser("bob@example.com", "Bob Brown")
	w.mallory, w.malTok = newUser("mallory@example.com", "Mallory Malicious")

	pairsCol, err := w.app.FindCollectionByNameOrId("pairs")
	if err != nil {
		t.Fatalf("pairs collection: %v", err)
	}
	newPair := func(name string) *core.Record {
		r := core.NewRecord(pairsCol)
		r.Set("name", name)
		if err := w.app.Save(r); err != nil {
			t.Fatalf("save pair %s: %v", name, err)
		}
		return r
	}
	w.flatmates = newPair("Flatmates")
	w.strangers = newPair("Strangers")

	membersCol, err := w.app.FindCollectionByNameOrId("pair_members")
	if err != nil {
		t.Fatalf("pair_members collection: %v", err)
	}
	addMember := func(pair, user *core.Record, role string) *core.Record {
		r := core.NewRecord(membersCol)
		r.Set("pair", pair.Id)
		r.Set("user", user.Id)
		r.Set("role", role)
		if err := w.app.Save(r); err != nil {
			t.Fatalf("save membership: %v", err)
		}
		return r
	}
	addMember(w.flatmates, w.alice, "owner")
	w.bobMembership = addMember(w.flatmates, w.bob, "member")
	addMember(w.strangers, w.mallory, "owner")

	// A moment of alice's, with a note, so there is private content to leak.
	postsCol, err := w.app.FindCollectionByNameOrId("posts")
	if err != nil {
		t.Fatalf("posts collection: %v", err)
	}
	w.alicePost = core.NewRecord(postsCol)
	w.alicePost.Set("pair", w.flatmates.Id)
	w.alicePost.Set("author", w.alice.Id)
	w.alicePost.Set("type", "event")
	w.alicePost.Set("event_kind", "beer")
	w.alicePost.Set("note", "secret-note-do-not-disclose")
	if err := w.app.Save(w.alicePost); err != nil {
		t.Fatalf("save post: %v", err)
	}

	reactionsCol, err := w.app.FindCollectionByNameOrId("reactions")
	if err != nil {
		t.Fatalf("reactions collection: %v", err)
	}
	w.aliceReaction = core.NewRecord(reactionsCol)
	w.aliceReaction.Set("post", w.alicePost.Id)
	w.aliceReaction.Set("user", w.alice.Id)
	w.aliceReaction.Set("kind", "cheers")
	if err := w.app.Save(w.aliceReaction); err != nil {
		t.Fatalf("save reaction: %v", err)
	}

	kindsCol, err := w.app.FindCollectionByNameOrId("moment_kinds")
	if err != nil {
		t.Fatalf("moment_kinds collection: %v", err)
	}
	w.aliceKind = core.NewRecord(kindsCol)
	w.aliceKind.Set("pair", w.flatmates.Id)
	w.aliceKind.Set("slug", "secret_ritual")
	w.aliceKind.Set("emoji", "🕯️")
	w.aliceKind.Set("label", "Secret Ritual")
	w.aliceKind.Set("created_by", w.alice.Id)
	if err := w.app.Save(w.aliceKind); err != nil {
		t.Fatalf("save moment kind: %v", err)
	}

	// A real avatar for alice, so the file-serving surface can be probed.
	raw, err := base64.StdEncoding.DecodeString(onePixelPNG)
	if err != nil {
		t.Fatalf("decode png: %v", err)
	}
	w.aliceAvatar = w.uploadAvatar(t, raw)
}

// uploadAvatar puts a photo on alice through the real route and returns the
// stored filename.
func (w *world) uploadAvatar(t *testing.T, raw []byte) string {
	t.Helper()

	// The mux does not exist yet during seeding, so this writes through the model
	// the same way the route does. The route itself is covered in internal/avatars.
	user, err := w.app.FindRecordById("users", w.alice.Id)
	if err != nil {
		t.Fatalf("reload alice: %v", err)
	}
	file, err := filesystem.NewFileFromBytes(raw, "avatar.png")
	if err != nil {
		t.Fatalf("build file: %v", err)
	}
	user.Set("avatar", []*filesystem.File{file})
	if err := w.app.Save(user); err != nil {
		t.Fatalf("save avatar: %v", err)
	}
	stored := user.GetString("avatar")
	if stored == "" {
		t.Fatalf("avatar did not store")
	}
	return stored
}

func (w *world) do(t *testing.T, method, path, token string) (int, string) {
	t.Helper()
	return w.doBody(t, method, path, token, "", nil)
}

func (w *world) doBody(t *testing.T, method, path, token, contentType string, body []byte) (int, string) {
	t.Helper()

	req := httptest.NewRequest(method, path, bytes.NewReader(body))
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if token != "" {
		req.Header.Set("Authorization", token)
	}
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	return rec.Code, rec.Body.String()
}

// listPath builds a collection list URL with a filter, correctly escaped — an
// unescaped filter silently becomes a different query and the test would pass
// for the wrong reason. An empty filter is omitted rather than sent as `filter=`,
// which PocketBase treats as a syntax error.
func listPath(collection, filter string) string {
	base := "/api/collections/" + collection + "/records?perPage=200"
	if filter == "" {
		return base
	}
	return base + "&filter=" + url.QueryEscape(filter)
}

// secrets are the strings that must never reach mallory, whatever the shape of
// the response. Asserting on the body rather than only on a status code catches
// a route that answers 200 with an unexpected envelope.
func (w *world) secrets() map[string]string {
	return map[string]string{
		"alice's email":        "alice@example.com",
		"bob's email":          "bob@example.com",
		"alice's display name": "Alice Anderson",
		"bob's display name":   "Bob Brown",
		"the note":             "secret-note-do-not-disclose",
		"the custom moment":    "Secret Ritual",
		"alice's avatar file":  w.aliceAvatar,
		"alice's user id":      w.alice.Id,
		"bob's user id":        w.bob.Id,
		"the connection id":    w.flatmates.Id,
	}
}

func (w *world) assertNoSecrets(t *testing.T, what, body string) {
	t.Helper()

	for name, secret := range w.secrets() {
		if secret == "" {
			continue
		}
		if strings.Contains(body, secret) {
			t.Errorf("%s disclosed %s (%q)\nbody: %s", what, name, secret, body)
		}
	}
}

// itemCount reads PocketBase's list envelope.
func itemCount(t *testing.T, body string) int {
	t.Helper()

	var payload struct {
		Items []json.RawMessage `json:"items"`
	}
	if err := json.Unmarshal([]byte(body), &payload); err != nil {
		t.Fatalf("decode list %q: %v", body, err)
	}
	return len(payload.Items)
}

// --- the collection API -----------------------------------------------------

func TestOutsiderCannotReadAnotherUsersRecord(t *testing.T) {
	w := newWorld(t)

	status, body := w.do(t, http.MethodGet, "/api/collections/users/records/"+w.alice.Id, w.malTok)
	if status == http.StatusOK {
		t.Errorf("reading alice's user record returned 200; body %s", body)
	}
	w.assertNoSecrets(t, "GET users/records/{alice}", body)
}

func TestUserListShowsOnlyYourself(t *testing.T) {
	w := newWorld(t)

	// The rule is `id = @request.auth.id`, so this is the whole disclosure
	// surface for the users collection: one row, your own.
	status, body := w.do(t, http.MethodGet, "/api/collections/users/records?perPage=200", w.malTok)
	if status != http.StatusOK {
		t.Fatalf("list users = %d; body %s", status, body)
	}
	if got := itemCount(t, body); got != 1 {
		t.Errorf("mallory saw %d users, want 1 (herself); body %s", got, body)
	}
	w.assertNoSecrets(t, "GET users/records", body)
}

// A filter naming somebody explicitly is the obvious probe, and the one a rule
// written as a list-only check would let through.
func TestUserListCannotBeFilteredToSomebodyElse(t *testing.T) {
	w := newWorld(t)

	for _, filter := range []string{
		fmt.Sprintf("id='%s'", w.alice.Id),
		"email='alice@example.com'",
		"display_name='Alice Anderson'",
		fmt.Sprintf("id!='%s'", w.mallory.Id),
	} {
		status, body := w.do(t, http.MethodGet, listPath("users", filter), w.malTok)
		if status != http.StatusOK {
			// A rejected filter is an acceptable answer; a disclosed one is not.
			continue
		}
		if got := itemCount(t, body); got != 0 {
			t.Errorf("filter %q returned %d users, want 0; body %s", filter, got, body)
		}
		w.assertNoSecrets(t, "GET users/records?filter="+filter, body)
	}
}

func TestOutsiderCannotReadAConnectionTheyAreNotIn(t *testing.T) {
	w := newWorld(t)

	status, body := w.do(t, http.MethodGet, "/api/collections/pairs/records/"+w.flatmates.Id, w.malTok)
	if status == http.StatusOK {
		t.Errorf("reading the Flatmates pair returned 200; body %s", body)
	}

	status, body = w.do(t, http.MethodGet, "/api/collections/pairs/records?perPage=200", w.malTok)
	if status != http.StatusOK {
		t.Fatalf("list pairs = %d; body %s", status, body)
	}
	if got := itemCount(t, body); got != 1 {
		t.Errorf("mallory saw %d pairs, want 1 (her own); body %s", got, body)
	}
	if !strings.Contains(body, w.strangers.Id) {
		t.Errorf("mallory could not see her own connection; body %s", body)
	}
	w.assertNoSecrets(t, "GET pairs/records", body)
}

// pair_members is the collection that maps people to connections, so it is the
// one that would turn "I know a pair id" into "I know who is in it".
func TestOutsiderCannotEnumerateMembership(t *testing.T) {
	w := newWorld(t)

	cases := []string{
		fmt.Sprintf("pair='%s'", w.flatmates.Id),
		fmt.Sprintf("user='%s'", w.alice.Id),
		fmt.Sprintf("user!='%s'", w.mallory.Id),
		"role='owner'",
	}
	for _, filter := range cases {
		status, body := w.do(t, http.MethodGet, listPath("pair_members", filter), w.malTok)
		if status != http.StatusOK {
			continue
		}
		for _, id := range []string{w.alice.Id, w.bob.Id, w.flatmates.Id} {
			if strings.Contains(body, id) {
				t.Errorf("filter %q disclosed %s; body %s", filter, id, body)
			}
		}
	}

	// And the direct read of a known membership row.
	status, body := w.do(t, http.MethodGet, "/api/collections/pair_members/records/"+w.bobMembership.Id, w.malTok)
	if status == http.StatusOK {
		t.Errorf("reading bob's membership returned 200; body %s", body)
	}
}

func TestOutsiderCannotReadPostsOrTheirNotes(t *testing.T) {
	w := newWorld(t)

	status, body := w.do(t, http.MethodGet, "/api/collections/posts/records/"+w.alicePost.Id, w.malTok)
	if status == http.StatusOK {
		t.Errorf("reading alice's post returned 200; body %s", body)
	}
	w.assertNoSecrets(t, "GET posts/records/{id}", body)

	for _, filter := range []string{
		fmt.Sprintf("pair='%s'", w.flatmates.Id),
		fmt.Sprintf("author='%s'", w.alice.Id),
		"type='event'",
	} {
		status, body := w.do(t, http.MethodGet, listPath("posts", filter), w.malTok)
		if status != http.StatusOK {
			continue
		}
		if got := itemCount(t, body); got != 0 {
			t.Errorf("filter %q returned %d posts, want 0; body %s", filter, got, body)
		}
		w.assertNoSecrets(t, "GET posts/records?filter="+filter, body)
	}
}

// `expand` is the classic way a scoped list still leaks: the rows are yours, the
// expansion is somebody else's. Probed from both directions — mallory expanding
// into alice, and bob (who legitimately sees the post) expanding into alice's
// user record, which he must not get either.
func TestExpandDoesNotDiscloseUserRecords(t *testing.T) {
	w := newWorld(t)

	status, body := w.do(t, http.MethodGet,
		listPath("posts", fmt.Sprintf("pair='%s'", w.flatmates.Id))+"&expand=author,pair", w.malTok)
	if status == http.StatusOK {
		if got := itemCount(t, body); got != 0 {
			t.Errorf("mallory expanded into %d posts, want 0; body %s", got, body)
		}
	}
	w.assertNoSecrets(t, "mallory: posts?expand=author,pair", body)

	// bob may read the post itself — that is the point of sharing a connection —
	// but `users.ViewRule` still applies to the expansion, so alice's email must
	// not arrive with it.
	status, body = w.do(t, http.MethodGet,
		listPath("posts", fmt.Sprintf("pair='%s'", w.flatmates.Id))+"&expand=author", w.bobTok)
	if status != http.StatusOK {
		t.Fatalf("bob listing shared posts = %d; body %s", status, body)
	}
	if got := itemCount(t, body); got != 1 {
		t.Fatalf("bob saw %d posts in his own connection, want 1; body %s", got, body)
	}
	if strings.Contains(body, "alice@example.com") {
		t.Errorf("expand=author disclosed alice's email to a co-member; body %s", body)
	}
}

func TestOutsiderCannotReadReactionsOrCustomMoments(t *testing.T) {
	w := newWorld(t)

	status, body := w.do(t, http.MethodGet,
		listPath("reactions", fmt.Sprintf("post='%s'", w.alicePost.Id)), w.malTok)
	if status == http.StatusOK {
		if got := itemCount(t, body); got != 0 {
			t.Errorf("mallory saw %d reactions, want 0; body %s", got, body)
		}
	}
	w.assertNoSecrets(t, "GET reactions", body)

	status, body = w.do(t, http.MethodGet,
		listPath("moment_kinds", fmt.Sprintf("pair='%s'", w.flatmates.Id)), w.malTok)
	if status == http.StatusOK {
		if got := itemCount(t, body); got != 0 {
			t.Errorf("mallory saw %d moment kinds, want 0; body %s", got, body)
		}
	}
	w.assertNoSecrets(t, "GET moment_kinds", body)
}

func TestOutsiderCannotWriteIntoAnotherConnection(t *testing.T) {
	w := newWorld(t)

	// Reading is the headline, but a connection nobody outside can read and
	// anybody outside can post into is just as broken.
	post := fmt.Sprintf(`{"pair":%q,"author":%q,"type":"event","event_kind":"beer"}`, w.flatmates.Id, w.mallory.Id)
	status, body := w.doBody(t, http.MethodPost, "/api/collections/posts/records", w.malTok,
		"application/json", []byte(post))
	if status == http.StatusOK {
		t.Errorf("mallory posted into Flatmates: %s", body)
	}

	// Renaming somebody else's connection.
	rename := `{"name":"Renamed By Mallory"}`
	status, body = w.doBody(t, http.MethodPatch, "/api/collections/pairs/records/"+w.flatmates.Id, w.malTok,
		"application/json", []byte(rename))
	if status == http.StatusOK {
		t.Errorf("mallory renamed Flatmates: %s", body)
	}
	stored, err := w.app.FindRecordById("pairs", w.flatmates.Id)
	if err != nil {
		t.Fatalf("reload pair: %v", err)
	}
	if got := stored.GetString("name"); got != "Flatmates" {
		t.Errorf("pair name = %q, want Flatmates", got)
	}

	// Joining by writing a membership row directly. pair_members has no
	// CreateRule, so this must be refused for everybody, not just outsiders.
	join := fmt.Sprintf(`{"pair":%q,"user":%q,"role":"member"}`, w.flatmates.Id, w.mallory.Id)
	status, body = w.doBody(t, http.MethodPost, "/api/collections/pair_members/records", w.malTok,
		"application/json", []byte(join))
	if status == http.StatusOK {
		t.Errorf("mallory added herself to Flatmates: %s", body)
	}
	count, err := w.app.CountRecords("pair_members", dbx.HashExp{"pair": w.flatmates.Id})
	if err != nil {
		t.Fatalf("count members: %v", err)
	}
	if count != 2 {
		t.Errorf("Flatmates has %d members, want 2", count)
	}
}

// --- memberless connections -------------------------------------------------

// Found on a live database, not by reading the rules: `GET /api/collections/pairs/records`
// with **no Authorization header at all** returned two rows. Both were pairs with
// zero members.
//
// The cause is the shape every scoped rule here uses. `pair_members_via_pair.user
// ?= @request.auth.id` compiles to a LEFT JOIN, so a pair with no members yields a
// NULL user — and comparing that against the empty `@request.auth.id` of a guest
// matched. An authenticated outsider was never affected: NULL against their real id
// is false. It is specifically the unauthenticated case that fell through.
//
// A memberless pair is reachable in ordinary use — leaving deletes the membership
// row and nothing deletes the connection behind it — and `posts`, `reactions` and
// `moment_kinds` are all scoped through the same join. So the last person leaving a
// connection published its entire timeline to the internet.
func TestAMemberlessConnectionIsNotWorldReadable(t *testing.T) {
	w := newWorld(t)

	orphan := w.memberlessPairWithContent(t)

	// The headline: no Authorization header at all.
	status, body := w.do(t, http.MethodGet, listPath("pairs", ""), "")
	if status == http.StatusOK {
		if strings.Contains(body, orphan.pair) {
			t.Errorf("a guest listed a memberless pair; body %s", body)
		}
		if strings.Contains(body, "Abandoned") {
			t.Errorf("a guest read a memberless pair's name; body %s", body)
		}
	}

	if status, body := w.do(t, http.MethodGet, "/api/collections/pairs/records/"+orphan.pair, ""); status == http.StatusOK {
		t.Errorf("a guest read a memberless pair directly; body %s", body)
	}

	// And everything scoped through the same join.
	for _, probe := range []struct{ what, path string }{
		{"posts", listPath("posts", fmt.Sprintf("pair='%s'", orphan.pair))},
		{"moment_kinds", listPath("moment_kinds", fmt.Sprintf("pair='%s'", orphan.pair))},
		{"reactions", listPath("reactions", fmt.Sprintf("post='%s'", orphan.post))},
		{"pair_members", listPath("pair_members", fmt.Sprintf("pair='%s'", orphan.pair))},
	} {
		status, body := w.do(t, http.MethodGet, probe.path, "")
		if status != http.StatusOK {
			continue
		}
		if got := itemCount(t, body); got != 0 {
			t.Errorf("a guest read %d %s rows of a memberless pair; body %s", got, probe.what, body)
		}
		if strings.Contains(body, "orphaned-note-do-not-disclose") {
			t.Errorf("a guest read a memberless pair's note via %s; body %s", probe.what, body)
		}
	}
}

// The same pair must also stay invisible to a signed-in stranger. This half always
// held — NULL never equals a real id — so it is here to keep the fix honest: a
// rule change that closed the guest hole by opening this one would fail.
func TestAMemberlessConnectionIsNotVisibleToASignedInStranger(t *testing.T) {
	w := newWorld(t)

	orphan := w.memberlessPairWithContent(t)

	status, body := w.do(t, http.MethodGet, listPath("pairs", ""), w.malTok)
	if status != http.StatusOK {
		t.Fatalf("list pairs = %d; body %s", status, body)
	}
	if strings.Contains(body, orphan.pair) {
		t.Errorf("a stranger listed a memberless pair; body %s", body)
	}
	// Her own connection is still there, so this is not passing by returning nothing.
	if !strings.Contains(body, w.strangers.Id) {
		t.Errorf("the stranger lost sight of her own connection; body %s", body)
	}

	status, body = w.do(t, http.MethodGet,
		listPath("posts", fmt.Sprintf("pair='%s'", orphan.pair)), w.malTok)
	if status == http.StatusOK && itemCount(t, body) != 0 {
		t.Errorf("a stranger read a memberless pair's posts; body %s", body)
	}
}

// A member still sees their own connection after the rule change — the guard must
// not cost the legitimate case anything.
func TestTheGuardDoesNotBreakAMembersOwnAccess(t *testing.T) {
	w := newWorld(t)

	status, body := w.do(t, http.MethodGet, listPath("pairs", ""), w.bobTok)
	if status != http.StatusOK {
		t.Fatalf("list pairs = %d; body %s", status, body)
	}
	if !strings.Contains(body, w.flatmates.Id) {
		t.Errorf("a member could not list their own connection; body %s", body)
	}
	if status, body := w.do(t, http.MethodGet, "/api/collections/pairs/records/"+w.flatmates.Id, w.bobTok); status != http.StatusOK {
		t.Errorf("a member could not read their own connection: %d %s", status, body)
	}
	for _, probe := range []string{
		listPath("posts", fmt.Sprintf("pair='%s'", w.flatmates.Id)),
		listPath("moment_kinds", fmt.Sprintf("pair='%s'", w.flatmates.Id)),
		listPath("reactions", fmt.Sprintf("post='%s'", w.alicePost.Id)),
		listPath("pair_members", fmt.Sprintf("pair='%s'", w.flatmates.Id)),
	} {
		status, body := w.do(t, http.MethodGet, probe, w.bobTok)
		if status != http.StatusOK {
			t.Errorf("%s = %d for a member; body %s", probe, status, body)
			continue
		}
		if itemCount(t, body) == 0 {
			t.Errorf("%s returned nothing to a member; body %s", probe, body)
		}
	}
}

type orphanedPair struct {
	pair string
	post string
}

// memberlessPairWithContent builds the state a connection is left in when its last
// member leaves: the pair, its posts, its reactions and its custom moments all
// survive, and not one `pair_members` row points at it.
func (w *world) memberlessPairWithContent(t *testing.T) orphanedPair {
	t.Helper()

	pairsCol, err := w.app.FindCollectionByNameOrId("pairs")
	if err != nil {
		t.Fatalf("pairs collection: %v", err)
	}
	pair := core.NewRecord(pairsCol)
	pair.Set("name", "Abandoned")
	if err := w.app.Save(pair); err != nil {
		t.Fatalf("save orphan pair: %v", err)
	}

	postsCol, err := w.app.FindCollectionByNameOrId("posts")
	if err != nil {
		t.Fatalf("posts collection: %v", err)
	}
	post := core.NewRecord(postsCol)
	post.Set("pair", pair.Id)
	post.Set("author", w.alice.Id)
	post.Set("type", "event")
	post.Set("event_kind", "beer")
	post.Set("note", "orphaned-note-do-not-disclose")
	if err := w.app.Save(post); err != nil {
		t.Fatalf("save orphan post: %v", err)
	}

	reactionsCol, err := w.app.FindCollectionByNameOrId("reactions")
	if err != nil {
		t.Fatalf("reactions collection: %v", err)
	}
	reaction := core.NewRecord(reactionsCol)
	reaction.Set("post", post.Id)
	reaction.Set("user", w.alice.Id)
	reaction.Set("kind", "cheers")
	if err := w.app.Save(reaction); err != nil {
		t.Fatalf("save orphan reaction: %v", err)
	}

	kindsCol, err := w.app.FindCollectionByNameOrId("moment_kinds")
	if err != nil {
		t.Fatalf("moment_kinds collection: %v", err)
	}
	kind := core.NewRecord(kindsCol)
	kind.Set("pair", pair.Id)
	kind.Set("slug", "orphan_ritual")
	kind.Set("emoji", "🕯️")
	kind.Set("label", "Orphan Ritual")
	kind.Set("created_by", w.alice.Id)
	if err := w.app.Save(kind); err != nil {
		t.Fatalf("save orphan kind: %v", err)
	}

	count, err := w.app.CountRecords("pair_members", dbx.HashExp{"pair": pair.Id})
	if err != nil {
		t.Fatalf("count orphan members: %v", err)
	}
	if count != 0 {
		t.Fatalf("orphan pair has %d members, want 0", count)
	}
	return orphanedPair{pair: pair.Id, post: post.Id}
}

// --- the custom routes ------------------------------------------------------

func TestConnectionsRouteReturnsOnlyYourOwn(t *testing.T) {
	w := newWorld(t)

	status, body := w.do(t, http.MethodGet, "/api/peard/connections", w.malTok)
	if status != http.StatusOK {
		t.Fatalf("connections = %d; body %s", status, body)
	}
	if !strings.Contains(body, w.strangers.Id) {
		t.Errorf("mallory's own connection missing; body %s", body)
	}
	w.assertNoSecrets(t, "GET /api/peard/connections", body)
}

// The positive control. Every assertion above is about absence, and absence is
// what a broken server returns too — so this proves the same route does disclose
// what it is supposed to, to somebody who shares the connection.
func TestCoMemberSeesNamesAndAvatarsButNeverEmail(t *testing.T) {
	w := newWorld(t)

	status, body := w.do(t, http.MethodGet, "/api/peard/connections", w.bobTok)
	if status != http.StatusOK {
		t.Fatalf("connections = %d; body %s", status, body)
	}
	for _, want := range []string{"Alice Anderson", w.aliceAvatar, w.flatmates.Id, "Flatmates"} {
		if !strings.Contains(body, want) {
			t.Errorf("co-member could not see %q; body %s", want, body)
		}
	}
	// The reason this route exists instead of relaxing users.ViewRule: names
	// travel, addresses do not.
	for _, never := range []string{"alice@example.com", "bob@example.com"} {
		if strings.Contains(body, never) {
			t.Errorf("connections route disclosed %q; body %s", never, body)
		}
	}
}

func TestTalliesRouteRefusesNonMembers(t *testing.T) {
	w := newWorld(t)

	status, body := w.do(t, http.MethodGet, "/api/peard/tallies?pair="+w.flatmates.Id, w.malTok)
	if status != http.StatusForbidden {
		t.Errorf("tallies for a foreign connection = %d, want 403; body %s", status, body)
	}
	w.assertNoSecrets(t, "GET /api/peard/tallies", body)

	// A member gets the numbers, so the 403 above is authorisation rather than a
	// broken query.
	if status, body := w.do(t, http.MethodGet, "/api/peard/tallies?pair="+w.flatmates.Id, w.bobTok); status != http.StatusOK {
		t.Errorf("tallies for a member = %d, want 200; body %s", status, body)
	}
}

func TestProfileRouteOnlyEverReturnsTheCaller(t *testing.T) {
	w := newWorld(t)

	status, body := w.do(t, http.MethodGet, "/api/peard/profile", w.malTok)
	if status != http.StatusOK {
		t.Fatalf("profile = %d; body %s", status, body)
	}
	if !strings.Contains(body, w.mallory.Id) {
		t.Errorf("profile did not return the caller; body %s", body)
	}
	w.assertNoSecrets(t, "GET /api/peard/profile", body)
}

func TestOutsiderCannotSetSomebodyElsesConnectionPhoto(t *testing.T) {
	w := newWorld(t)

	raw, err := base64.StdEncoding.DecodeString(onePixelPNG)
	if err != nil {
		t.Fatalf("decode png: %v", err)
	}
	var buf bytes.Buffer
	writer := multipart.NewWriter(&buf)
	if err := writer.WriteField("pair", w.flatmates.Id); err != nil {
		t.Fatalf("write field: %v", err)
	}
	part, err := writer.CreateFormFile("avatar", "x.png")
	if err != nil {
		t.Fatalf("form file: %v", err)
	}
	if _, err := part.Write(raw); err != nil {
		t.Fatalf("write png: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	status, body := w.doBody(t, http.MethodPost, "/api/peard/connections/avatar", w.malTok,
		writer.FormDataContentType(), buf.Bytes())
	if status != http.StatusForbidden {
		t.Errorf("setting a foreign group photo = %d, want 403; body %s", status, body)
	}

	status, body = w.do(t, http.MethodDelete, "/api/peard/connections/avatar?pair="+w.flatmates.Id, w.malTok)
	if status != http.StatusForbidden {
		t.Errorf("clearing a foreign group photo = %d, want 403; body %s", status, body)
	}
}

// --- files ------------------------------------------------------------------

// Avatar files are deliberately unprotected, so the URL is the capability. That
// is only defensible if the URL cannot be derived from a user id, which is what
// PocketBase's random filename suffix is for. Asserted rather than assumed,
// because the whole privacy argument for unprotected avatars rests on it.
func TestAvatarFilenameCannotBeGuessedFromAUserID(t *testing.T) {
	w := newWorld(t)

	for _, guess := range []string{"avatar.png", "x.png", "avatar.jpg", "1.png"} {
		path := "/api/files/users/" + w.alice.Id + "/" + guess
		if status, body := w.do(t, http.MethodGet, path, w.malTok); status == http.StatusOK {
			t.Errorf("guessed avatar path %s returned 200; body %s", path, body)
		}
	}

	// The stored name carries a random suffix, so it is not the upload's name.
	if strings.HasPrefix(w.aliceAvatar, "avatar.") {
		t.Errorf("stored filename %q was not randomised", w.aliceAvatar)
	}

	// And listing a record's files is not a thing PocketBase offers, so knowing
	// the id gets an outsider no closer.
	if status, body := w.do(t, http.MethodGet, "/api/files/users/"+w.alice.Id, w.malTok); status == http.StatusOK {
		t.Errorf("listing alice's files returned 200; body %s", body)
	}
}

// --- leaving ----------------------------------------------------------------

// Membership is the whole basis of visibility, so it has to be revocable: what
// bob can see must stop being visible when he is no longer in the connection.
func TestLeavingAConnectionRevokesVisibility(t *testing.T) {
	w := newWorld(t)

	// Before: bob sees the post and alice's name.
	if status, body := w.do(t, http.MethodGet, "/api/collections/posts/records/"+w.alicePost.Id, w.bobTok); status != http.StatusOK {
		t.Fatalf("bob could not read a post in his own connection: %d %s", status, body)
	}

	if err := w.app.Delete(w.bobMembership); err != nil {
		t.Fatalf("remove bob: %v", err)
	}

	status, body := w.do(t, http.MethodGet, "/api/collections/posts/records/"+w.alicePost.Id, w.bobTok)
	if status == http.StatusOK {
		t.Errorf("a former member still reads the post; body %s", body)
	}

	status, body = w.do(t, http.MethodGet, "/api/peard/connections", w.bobTok)
	if status != http.StatusOK {
		t.Fatalf("connections = %d; body %s", status, body)
	}
	if strings.Contains(body, "Alice Anderson") {
		t.Errorf("a former member still sees alice's name; body %s", body)
	}

	if status, body := w.do(t, http.MethodGet, "/api/peard/tallies?pair="+w.flatmates.Id, w.bobTok); status != http.StatusForbidden {
		t.Errorf("tallies for a former member = %d, want 403; body %s", status, body)
	}
}
