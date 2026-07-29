package auth

import (
	"os"
	"testing"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	_ "peard/migrations"
)

// The unit tests cover the policy; this covers the effect. applyNotificationAction
// touches five collections in one transaction, and the parts that matter — an
// auth token no longer validating, a widget token flipping to revoked, the
// cascade reaching another member's timeline — cannot be asserted without a real
// schema behind it.
//
// tests.NewTestApp clones the given directory and runs every registered
// migration, so an empty temp dir yields a fresh database with Pear'd's full
// schema.
func newIntegrationApp(t testing.TB) *tests.TestApp {
	t.Helper()

	dir, err := os.MkdirTemp("", "peard-auth-test-*")
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
	return app
}

type fixture struct {
	user        *core.Record
	other       *core.Record
	pair        *core.Record
	post        *core.Record
	otherPost   *core.Record
	device      *core.Record
	widgetToken *core.Record
	authToken   string
}

// seed builds a two-person connection where both members have posted, so the
// cascade's reach is observable.
func seed(t testing.TB, app core.App, appleSub string) *fixture {
	t.Helper()

	usersCol, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("users collection: %v", err)
	}

	newUser := func(email, name string) *core.Record {
		r := core.NewRecord(usersCol)
		r.SetEmail(email)
		r.SetVerified(true)
		r.Set("display_name", name)
		r.SetPassword("Password123!")
		if err := app.Save(r); err != nil {
			t.Fatalf("save user %s: %v", email, err)
		}
		return r
	}

	f := &fixture{}
	f.user = newUser("apple-user@example.com", "Apple User")
	f.other = newUser("friend@example.com", "Friend")

	pairsCol, err := app.FindCollectionByNameOrId("pairs")
	if err != nil {
		t.Fatalf("pairs collection: %v", err)
	}
	f.pair = core.NewRecord(pairsCol)
	f.pair.Set("name", "Test Connection")
	if err := app.Save(f.pair); err != nil {
		t.Fatalf("save pair: %v", err)
	}

	membersCol, err := app.FindCollectionByNameOrId("pair_members")
	if err != nil {
		t.Fatalf("pair_members collection: %v", err)
	}
	for user, role := range map[*core.Record]string{f.user: "owner", f.other: "member"} {
		m := core.NewRecord(membersCol)
		m.Set("pair", f.pair.Id)
		m.Set("user", user.Id)
		m.Set("role", role)
		if err := app.Save(m); err != nil {
			t.Fatalf("save membership: %v", err)
		}
	}

	postsCol, err := app.FindCollectionByNameOrId("posts")
	if err != nil {
		t.Fatalf("posts collection: %v", err)
	}
	newPost := func(author *core.Record, kind string) *core.Record {
		p := core.NewRecord(postsCol)
		p.Set("pair", f.pair.Id)
		p.Set("author", author.Id)
		p.Set("type", "event")
		p.Set("event_kind", kind)
		if err := app.Save(p); err != nil {
			t.Fatalf("save post: %v", err)
		}
		return p
	}
	f.post = newPost(f.user, "beer")
	f.otherPost = newPost(f.other, "coffee")

	devicesCol, err := app.FindCollectionByNameOrId("devices")
	if err != nil {
		t.Fatalf("devices collection: %v", err)
	}
	f.device = core.NewRecord(devicesCol)
	f.device.Set("user", f.user.Id)
	f.device.Set("platform", "ios")
	f.device.Set("push_token", "aaaabbbbccccdddd")
	if err := app.Save(f.device); err != nil {
		t.Fatalf("save device: %v", err)
	}

	wtCol, err := app.FindCollectionByNameOrId("widget_tokens")
	if err != nil {
		t.Fatalf("widget_tokens collection: %v", err)
	}
	f.widgetToken = core.NewRecord(wtCol)
	f.widgetToken.Set("user", f.user.Id)
	f.widgetToken.Set("token", "widget-token-value")
	f.widgetToken.Set("revoked", false)
	if err := app.Save(f.widgetToken); err != nil {
		t.Fatalf("save widget token: %v", err)
	}

	linkAppleExternalAuth(app, f.user, appleSub)

	token, err := f.user.NewAuthToken()
	if err != nil {
		t.Fatalf("mint auth token: %v", err)
	}
	f.authToken = token

	// The token has to work before the action, or asserting that it stops
	// working afterwards proves nothing.
	if _, err := app.FindAuthRecordByToken(f.authToken, core.TokenTypeAuth); err != nil {
		t.Fatalf("freshly minted auth token should validate: %v", err)
	}
	return f
}

func countByFilter(t *testing.T, app core.App, collection, filter string, params dbx.Params) int {
	t.Helper()
	records, err := app.FindRecordsByFilter(collection, filter, "", 0, 0, params)
	if err != nil {
		t.Fatalf("query %s: %v", collection, err)
	}
	return len(records)
}

// consent-revoked: every way in is closed, and nothing anybody can see is lost.
func TestApplyNotificationActionRevokeAccess(t *testing.T) {
	app := newIntegrationApp(t)
	f := seed(t, app, "000123.consent.0001")

	user, err := app.FindRecordById("users", f.user.Id)
	if err != nil {
		t.Fatalf("find user: %v", err)
	}
	if err := applyNotificationAction(app, user, actionRevokeAccess); err != nil {
		t.Fatalf("applyNotificationAction: %v", err)
	}

	// The session is dead: this is the point of the event.
	if _, err := app.FindAuthRecordByToken(f.authToken, core.TokenTypeAuth); err == nil {
		t.Error("the auth token issued before revocation must stop validating")
	}

	if n := countByFilter(t, app, "devices", "user = {:u}", dbx.Params{"u": f.user.Id}); n != 0 {
		t.Errorf("devices remaining = %d, want 0 (pushes must stop)", n)
	}

	wt, err := app.FindRecordById("widget_tokens", f.widgetToken.Id)
	if err != nil {
		t.Fatalf("find widget token: %v", err)
	}
	if !wt.GetBool("revoked") {
		t.Error("widget token must be revoked; it lives in the App Group and outlives the session")
	}

	if n := countByFilter(t, app, core.CollectionNameExternalAuths,
		"recordRef = {:u} && provider = 'apple'", dbx.Params{"u": f.user.Id}); n != 0 {
		t.Errorf("apple external auth links = %d, want 0", n)
	}

	// Revocation is not deletion. The account and both members' moments stay.
	if _, err := app.FindRecordById("users", f.user.Id); err != nil {
		t.Errorf("user must survive a consent-revoked: %v", err)
	}
	if n := countByFilter(t, app, "posts", "pair = {:p}", dbx.Params{"p": f.pair.Id}); n != 2 {
		t.Errorf("posts in the connection = %d, want 2", n)
	}
}

// Running twice must be safe: Apple retries, and a retry arrives as the same
// event on an already-revoked account.
func TestApplyNotificationActionIsIdempotent(t *testing.T) {
	app := newIntegrationApp(t)
	f := seed(t, app, "000123.retry.0001")

	for i := range 2 {
		user, err := app.FindRecordById("users", f.user.Id)
		if err != nil {
			t.Fatalf("find user (pass %d): %v", i+1, err)
		}
		if err := applyNotificationAction(app, user, actionRevokeAccess); err != nil {
			t.Fatalf("applyNotificationAction (pass %d): %v", i+1, err)
		}
	}

	if n := countByFilter(t, app, "devices", "user = {:u}", dbx.Params{"u": f.user.Id}); n != 0 {
		t.Errorf("devices remaining = %d, want 0", n)
	}
	if _, err := app.FindRecordById("users", f.user.Id); err != nil {
		t.Errorf("user must still exist after a repeated revocation: %v", err)
	}
}

// actionErase is the opt-in path, and this is the blast radius it carries: the
// cascade takes the user's moments out of a timeline the other member can see.
// The test asserts that consequence rather than only the deletion, because it is
// the reason the behaviour is not the default.
func TestApplyNotificationActionEraseCascadesIntoSharedTimeline(t *testing.T) {
	app := newIntegrationApp(t)
	f := seed(t, app, "000123.erase.0001")

	user, err := app.FindRecordById("users", f.user.Id)
	if err != nil {
		t.Fatalf("find user: %v", err)
	}
	if err := applyNotificationAction(app, user, actionErase); err != nil {
		t.Fatalf("applyNotificationAction: %v", err)
	}

	if _, err := app.FindRecordById("users", f.user.Id); err == nil {
		t.Error("the user record must be gone")
	}
	if _, err := app.FindRecordById("posts", f.post.Id); err == nil {
		t.Error("the erased user's own post must be gone")
	}
	if n := countByFilter(t, app, "pair_members", "user = {:u}", dbx.Params{"u": f.user.Id}); n != 0 {
		t.Errorf("memberships remaining = %d, want 0", n)
	}

	// The other member keeps their own moments and their place in the
	// connection: the cascade must not reach further than the deleted user.
	if _, err := app.FindRecordById("posts", f.otherPost.Id); err != nil {
		t.Errorf("the other member's post must survive: %v", err)
	}
	if _, err := app.FindRecordById("users", f.other.Id); err != nil {
		t.Errorf("the other member must survive: %v", err)
	}
	if n := countByFilter(t, app, "posts", "pair = {:p}", dbx.Params{"p": f.pair.Id}); n != 1 {
		t.Errorf("posts left in the connection = %d, want 1", n)
	}
}

// findUserByAppleSub prefers the recorded Apple sub, and falls back to the email
// because the _externalAuths link is written best-effort at sign-in.
func TestFindUserByAppleSub(t *testing.T) {
	app := newIntegrationApp(t)
	f := seed(t, app, "000123.lookup.0001")

	if got := findUserByAppleSub(app, "000123.lookup.0001", ""); got == nil || got.Id != f.user.Id {
		t.Error("should resolve by apple sub alone")
	}
	if got := findUserByAppleSub(app, "", "apple-user@example.com"); got == nil || got.Id != f.user.Id {
		t.Error("should resolve by email when no sub matches")
	}
	// Apple's relay addresses arrive in whatever case Apple used; the record is
	// stored lower-cased.
	if got := findUserByAppleSub(app, "", "Apple-User@Example.com "); got == nil || got.Id != f.user.Id {
		t.Error("email lookup should be case- and space-insensitive")
	}
	if got := findUserByAppleSub(app, "no.such.sub", "nobody@example.com"); got != nil {
		t.Error("an unknown sub and email must resolve to nothing")
	}
	// A sub belonging to nobody must not silently match on the email of a
	// different account.
	if got := findUserByAppleSub(app, "no.such.sub", "friend@example.com"); got == nil || got.Id != f.other.Id {
		t.Error("email fallback should find the account that owns the email")
	}
}
