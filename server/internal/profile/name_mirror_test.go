package profile_test

import (
	"os"
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"peard/internal/profile"
)

func newApp(t *testing.T) *tests.TestApp {
	t.Helper()
	dir, err := os.MkdirTemp("", "peard-profile-test-*")
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
	profile.Register(app)
	return app
}

func newUser(t *testing.T, app *tests.TestApp, email, display, name string) *core.Record {
	t.Helper()
	col, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("users collection: %v", err)
	}
	r := core.NewRecord(col)
	r.SetEmail(email)
	r.SetPassword("Password123!")
	r.Set("display_name", display)
	if name != "" {
		r.Set("name", name)
	}
	if err := app.Save(r); err != nil {
		t.Fatalf("save user: %v", err)
	}
	return r
}

// PocketBase's admin console labels a relation with `name`, which Pear'd never
// writes — so every pair_members row, post and reaction rendered as a bare
// record id.
func TestNameIsFilledFromDisplayNameOnCreate(t *testing.T) {
	app := newApp(t)

	user := newUser(t, app, "ada@example.com", "Ada", "")

	if got := user.GetString("name"); got != "Ada" {
		t.Fatalf("name = %q, want %q", got, "Ada")
	}
}

// Somebody who sets `name` in the console meant to. Overwriting it on the next
// profile save would be worse than the problem this fixes.
func TestAnExistingNameIsLeftAlone(t *testing.T) {
	app := newApp(t)

	user := newUser(t, app, "ada@example.com", "Ada", "Ada Lovelace")

	if got := user.GetString("name"); got != "Ada Lovelace" {
		t.Fatalf("name = %q, want it untouched", got)
	}
}

// Renaming yourself in the app should move the console label too, for the
// accounts where it is only ever a mirror.
func TestRenamingUpdatesAMirroredName(t *testing.T) {
	app := newApp(t)
	user := newUser(t, app, "ada@example.com", "Ada", "")

	user.Set("display_name", "Ada L")
	user.Set("name", "")
	if err := app.Save(user); err != nil {
		t.Fatalf("save: %v", err)
	}

	if got := user.GetString("name"); got != "Ada L" {
		t.Fatalf("name = %q, want %q", got, "Ada L")
	}
}

// Nothing to mirror is not an error, and must not write an empty string over
// whatever a future migration puts there.
func TestNoDisplayNameLeavesNameBlank(t *testing.T) {
	app := newApp(t)

	user := newUser(t, app, "ada@example.com", "", "")

	if got := user.GetString("name"); got != "" {
		t.Fatalf("name = %q, want blank", got)
	}
}
