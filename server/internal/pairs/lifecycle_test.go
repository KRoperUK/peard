// Package pairs_test is external to `pairs` on purpose: these tests need the real
// Pear'd schema, which comes from blank-importing `peard/migrations`, and that
// package imports `peard/internal/pairs`. An in-package test file would make that
// an import cycle.
package pairs_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
	"github.com/pocketbase/pocketbase/tools/types"

	"peard/internal/pairs"

	_ "peard/migrations"
)

const testPassword = "Password123!"

// lifeWorld is a connection with content in it, plus a second untouched
// connection so every deletion can be checked for blast radius.
type lifeWorld struct {
	app *tests.TestApp
	mux http.Handler

	alice, bob           *core.Record
	aliceTok, bobTok     string
	flatmates, elsewhere *core.Record

	// Content of `flatmates`, all of which must go when it does.
	post     *core.Record
	reaction *core.Record
	kind     *core.Record
	invite   *core.Record

	// Content of `elsewhere`, none of which may go.
	otherPost *core.Record
}

func newLifeWorld(t *testing.T) *lifeWorld {
	t.Helper()

	dir, err := os.MkdirTemp("", "peard-pairs-test-*")
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

	// Registers the routes *and* the pair_members delete hook under test.
	pairs.Register(app)

	w := &lifeWorld{app: app}
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

func (w *lifeWorld) seed(t *testing.T) {
	t.Helper()

	w.alice, w.aliceTok = w.newUser(t, "alice@example.com", "Alice Anderson")
	w.bob, w.bobTok = w.newUser(t, "bob@example.com", "Bob Brown")

	w.flatmates = w.newPair(t, "Flatmates")
	w.elsewhere = w.newPair(t, "Elsewhere")

	w.addMember(t, w.flatmates, w.alice, "owner")
	w.addMember(t, w.elsewhere, w.bob, "owner")

	w.post = w.newPost(t, w.flatmates, w.alice, "beer", "pub basement")
	w.reaction = w.newReaction(t, w.post, w.alice)
	w.kind = w.newKind(t, w.flatmates, w.alice, "dog_walk")
	w.invite = w.newInvite(t, w.flatmates, w.alice)

	w.otherPost = w.newPost(t, w.elsewhere, w.bob, "coffee", "unrelated")
}

func (w *lifeWorld) newUser(t *testing.T, email, display string) (*core.Record, string) {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("users collection: %v", err)
	}
	r := core.NewRecord(col)
	r.SetEmail(email)
	r.SetVerified(true)
	r.SetPassword(testPassword)
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

func (w *lifeWorld) newPair(t *testing.T, name string) *core.Record {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("pairs")
	if err != nil {
		t.Fatalf("pairs collection: %v", err)
	}
	r := core.NewRecord(col)
	r.Set("name", name)
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save pair %s: %v", name, err)
	}
	return r
}

func (w *lifeWorld) addMember(t *testing.T, pair, user *core.Record, role string) *core.Record {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("pair_members")
	if err != nil {
		t.Fatalf("pair_members collection: %v", err)
	}
	r := core.NewRecord(col)
	r.Set("pair", pair.Id)
	r.Set("user", user.Id)
	r.Set("role", role)
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save membership: %v", err)
	}
	return r
}

func (w *lifeWorld) newPost(t *testing.T, pair, author *core.Record, kind, note string) *core.Record {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("posts")
	if err != nil {
		t.Fatalf("posts collection: %v", err)
	}
	r := core.NewRecord(col)
	r.Set("pair", pair.Id)
	r.Set("author", author.Id)
	r.Set("type", "event")
	r.Set("event_kind", kind)
	r.Set("note", note)
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save post: %v", err)
	}
	return r
}

func (w *lifeWorld) newReaction(t *testing.T, post, user *core.Record) *core.Record {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("reactions")
	if err != nil {
		t.Fatalf("reactions collection: %v", err)
	}
	r := core.NewRecord(col)
	r.Set("post", post.Id)
	r.Set("user", user.Id)
	r.Set("kind", "cheers")
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save reaction: %v", err)
	}
	return r
}

func (w *lifeWorld) newKind(t *testing.T, pair, by *core.Record, slug string) *core.Record {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("moment_kinds")
	if err != nil {
		t.Fatalf("moment_kinds collection: %v", err)
	}
	r := core.NewRecord(col)
	r.Set("pair", pair.Id)
	r.Set("slug", slug)
	r.Set("emoji", "🚶")
	r.Set("label", "Dog walk")
	r.Set("created_by", by.Id)
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save moment kind: %v", err)
	}
	return r
}

func (w *lifeWorld) newInvite(t *testing.T, pair, inviter *core.Record) *core.Record {
	t.Helper()
	col, err := w.app.FindCollectionByNameOrId("pair_invites")
	if err != nil {
		t.Fatalf("pair_invites collection: %v", err)
	}
	r := core.NewRecord(col)
	r.Set("code", "ABCDEF")
	r.Set("inviter", inviter.Id)
	r.Set("status", "pending")
	r.Set("pair", pair.Id)
	r.Set("expires", time.Now().Add(24*time.Hour).UTC().Format(types.DefaultDateLayout))
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save invite: %v", err)
	}
	return r
}

func (w *lifeWorld) do(t *testing.T, method, path, token, body string) (int, string) {
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

// exists reports whether a record is still in the database. Anything other than a
// clean hit or a clean miss fails the test, so a query error can never be read as
// "it was deleted".
func (w *lifeWorld) exists(t *testing.T, collection, id string) bool {
	t.Helper()
	n, err := w.app.CountRecords(collection, dbx.HashExp{"id": id})
	if err != nil {
		t.Fatalf("count %s %s: %v", collection, id, err)
	}
	return n > 0
}

func (w *lifeWorld) assertGone(t *testing.T, what, collection, id string) {
	t.Helper()
	if w.exists(t, collection, id) {
		t.Errorf("%s should have been deleted with the connection, but %s/%s remains", what, collection, id)
	}
}

func (w *lifeWorld) assertPresent(t *testing.T, what, collection, id string) {
	t.Helper()
	if !w.exists(t, collection, id) {
		t.Errorf("%s should have survived, but %s/%s is gone", what, collection, id)
	}
}

// assertElsewhereIntact is the blast-radius check every deleting test runs: the
// connection alice was never in, and the moment in it, must be untouched.
func (w *lifeWorld) assertElsewhereIntact(t *testing.T) {
	t.Helper()
	w.assertPresent(t, "the unrelated connection", "pairs", w.elsewhere.Id)
	w.assertPresent(t, "the unrelated connection's moment", "posts", w.otherPost.Id)
	w.assertPresent(t, "bob's account", "users", w.bob.Id)
}

// --- the invariant, through each door that deletes a membership -------------

func TestLeavingAsLastMemberDeletesConnectionAndItsContents(t *testing.T) {
	w := newLifeWorld(t)

	status, body := w.do(t, http.MethodPost, "/api/peard/pairs/leave", w.aliceTok,
		`{"pair":"`+w.flatmates.Id+`"}`)
	if status != http.StatusOK {
		t.Fatalf("leave: status %d, body %s", status, body)
	}

	w.assertGone(t, "the emptied connection", "pairs", w.flatmates.Id)
	w.assertGone(t, "its moment", "posts", w.post.Id)
	w.assertGone(t, "the reaction to that moment", "reactions", w.reaction.Id)
	w.assertGone(t, "its custom moment", "moment_kinds", w.kind.Id)
	w.assertGone(t, "its pending invite", "pair_invites", w.invite.Id)

	// Leaving is not account deletion: alice keeps her account and could pair
	// again tomorrow.
	w.assertPresent(t, "alice's account", "users", w.alice.Id)
	w.assertElsewhereIntact(t)
}

func TestLeavingWhenOthersRemainKeepsConnection(t *testing.T) {
	w := newLifeWorld(t)
	bobMembership := w.addMember(t, w.flatmates, w.bob, "member")

	status, body := w.do(t, http.MethodPost, "/api/peard/pairs/leave", w.bobTok,
		`{"pair":"`+w.flatmates.Id+`"}`)
	if status != http.StatusOK {
		t.Fatalf("leave: status %d, body %s", status, body)
	}

	w.assertGone(t, "bob's membership", "pair_members", bobMembership.Id)
	w.assertPresent(t, "the connection alice is still in", "pairs", w.flatmates.Id)
	// The shared timeline is the point of the connection: one person leaving a
	// group must not erase the history the others can still see.
	w.assertPresent(t, "the shared moment", "posts", w.post.Id)
	w.assertPresent(t, "the custom moment", "moment_kinds", w.kind.Id)
}

func TestDeletingOwnMembershipThroughCollectionAPIDeletesEmptiedConnection(t *testing.T) {
	w := newLifeWorld(t)

	// The door the route does not own: `pair_members.DeleteRule` is
	// `user = @request.auth.id`, so a client can delete its own membership
	// directly and never call /leave. Enforcing the invariant in the route alone
	// would leave this producing an orphan.
	membership, err := w.app.FindFirstRecordByFilter("pair_members",
		"pair = {:pair} && user = {:user}",
		dbx.Params{"pair": w.flatmates.Id, "user": w.alice.Id})
	if err != nil {
		t.Fatalf("find alice's membership: %v", err)
	}

	status, body := w.do(t, http.MethodDelete,
		"/api/collections/pair_members/records/"+membership.Id, w.aliceTok, "")
	if status != http.StatusNoContent {
		t.Fatalf("collection delete: status %d, body %s", status, body)
	}

	w.assertGone(t, "the emptied connection", "pairs", w.flatmates.Id)
	w.assertGone(t, "its moment", "posts", w.post.Id)
	w.assertElsewhereIntact(t)
}

func TestDeletingUserDeletesConnectionsThatOnlyHeldThem(t *testing.T) {
	w := newLifeWorld(t)

	// The Apple `account-delete` erase path, and a superuser deleting somebody
	// from the dashboard: `pair_members.user` cascades, so the memberships
	// vanish without any Pear'd route being called.
	alice, err := w.app.FindRecordById("users", w.alice.Id)
	if err != nil {
		t.Fatalf("reload alice: %v", err)
	}
	if err := w.app.Delete(alice); err != nil {
		t.Fatalf("delete alice: %v", err)
	}

	w.assertGone(t, "the connection only alice was in", "pairs", w.flatmates.Id)
	w.assertGone(t, "its custom moment", "moment_kinds", w.kind.Id)
	w.assertElsewhereIntact(t)
}

func TestDeletingUserKeepsConnectionsThatStillHaveMembers(t *testing.T) {
	w := newLifeWorld(t)
	w.addMember(t, w.flatmates, w.bob, "member")
	bobPost := w.newPost(t, w.flatmates, w.bob, "loo", "bob's moment")

	alice, err := w.app.FindRecordById("users", w.alice.Id)
	if err != nil {
		t.Fatalf("reload alice: %v", err)
	}
	if err := w.app.Delete(alice); err != nil {
		t.Fatalf("delete alice: %v", err)
	}

	w.assertPresent(t, "the connection bob is still in", "pairs", w.flatmates.Id)
	w.assertPresent(t, "bob's own moment", "posts", bobPost.Id)
	// alice's posts go with her account — `posts.author` cascades — which is the
	// documented consequence of erasing an account, not of emptying a connection.
	w.assertGone(t, "alice's moment", "posts", w.post.Id)
}

func TestRemovingSomebodyNeverEmptiesConnection(t *testing.T) {
	w := newLifeWorld(t)
	w.addMember(t, w.flatmates, w.bob, "member")

	status, body := w.do(t, http.MethodPost, "/api/peard/pairs/remove", w.aliceTok,
		`{"pair":"`+w.flatmates.Id+`","user":"`+w.bob.Id+`"}`)
	if status != http.StatusOK {
		t.Fatalf("remove: status %d, body %s", status, body)
	}

	// /remove refuses to remove the caller, so the owner always remains and the
	// connection can never empty through this route.
	w.assertPresent(t, "the connection the owner is still in", "pairs", w.flatmates.Id)
	w.assertPresent(t, "the shared moment", "posts", w.post.Id)
}

func TestDeletingConnectionDirectlyDoesNotRecurse(t *testing.T) {
	w := newLifeWorld(t)
	w.addMember(t, w.flatmates, w.bob, "member")

	// Deleting the pair cascades to its members, which fires the same hook. That
	// must terminate rather than re-entering: PocketBase deletes the main record
	// before its references, so the hook finds the pair already gone.
	pair, err := w.app.FindRecordById("pairs", w.flatmates.Id)
	if err != nil {
		t.Fatalf("reload pair: %v", err)
	}

	done := make(chan error, 1)
	go func() { done <- w.app.Delete(pair) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("delete pair: %v", err)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("deleting a connection did not finish — the delete hook is re-entering")
	}

	w.assertGone(t, "the connection", "pairs", w.flatmates.Id)
	w.assertGone(t, "its moment", "posts", w.post.Id)
	remaining, err := w.app.CountRecords("pair_members", dbx.HashExp{"pair": w.flatmates.Id})
	if err != nil {
		t.Fatalf("count memberships: %v", err)
	}
	if remaining != 0 {
		t.Errorf("memberships remaining after the connection was deleted = %d, want 0", remaining)
	}
	w.assertElsewhereIntact(t)
}

// --- reconciling orphans that already exist ---------------------------------

func TestDeleteMemberlessPairsDeletesOnlyOrphans(t *testing.T) {
	w := newLifeWorld(t)

	// An orphan of the kind the migration exists to clear: a connection whose
	// members are gone but whose content is not. Written straight to the model,
	// because the hook now makes it unreachable through any route.
	orphan := w.newPair(t, "Abandoned")
	orphanPost := w.newPost(t, orphan, w.alice, "beer", "nobody can see this")
	orphanKind := w.newKind(t, orphan, w.alice, "ghost")

	deleted, err := pairs.DeleteMemberlessPairs(w.app)
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if deleted != 1 {
		t.Errorf("pairs deleted = %d, want 1", deleted)
	}

	w.assertGone(t, "the orphaned connection", "pairs", orphan.Id)
	w.assertGone(t, "its moment", "posts", orphanPost.Id)
	w.assertGone(t, "its custom moment", "moment_kinds", orphanKind.Id)

	// Both populated connections survive, so the sweep is not simply deleting
	// everything.
	w.assertPresent(t, "alice's connection", "pairs", w.flatmates.Id)
	w.assertPresent(t, "alice's moment", "posts", w.post.Id)
	w.assertElsewhereIntact(t)
}

func TestDeleteMemberlessPairsIsIdempotent(t *testing.T) {
	w := newLifeWorld(t)
	w.newPair(t, "Abandoned")

	if _, err := pairs.DeleteMemberlessPairs(w.app); err != nil {
		t.Fatalf("first sweep: %v", err)
	}
	// Migrations may be re-run against a partially applied database, so a second
	// pass must be a no-op rather than an error.
	deleted, err := pairs.DeleteMemberlessPairs(w.app)
	if err != nil {
		t.Fatalf("second sweep: %v", err)
	}
	if deleted != 0 {
		t.Errorf("pairs deleted on the second pass = %d, want 0", deleted)
	}
	w.assertPresent(t, "alice's connection", "pairs", w.flatmates.Id)
}
