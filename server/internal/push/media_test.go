package push

import (
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	_ "peard/migrations"
)

func newMediaApp(t *testing.T) *tests.TestApp {
	t.Helper()
	dir, err := os.MkdirTemp("", "peard-push-media-*")
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
	app.Settings().Meta.AppURL = "https://peard.example"
	return app
}

func newRecord(t *testing.T, app core.App, collection string, fields map[string]any) *core.Record {
	t.Helper()
	col, err := app.FindCollectionByNameOrId(collection)
	if err != nil {
		t.Fatalf("%s collection: %v", collection, err)
	}
	r := core.NewRecord(col)
	for k, v := range fields {
		r.Set(k, v)
	}
	// Without validation so a photo can name a stored file without uploading one.
	if err := app.SaveNoValidate(r); err != nil {
		t.Fatalf("save %s: %v", collection, err)
	}
	return r
}

func newUser(t *testing.T, app core.App, email string) *core.Record {
	t.Helper()
	col, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("users collection: %v", err)
	}
	u := core.NewRecord(col)
	u.SetEmail(email)
	u.SetPassword("password123")
	if err := app.Save(u); err != nil {
		t.Fatalf("save user: %v", err)
	}
	return u
}

// A photo's alert carries a thumbnail the recipient's device can fetch without
// a session: the token in it is a file token for the recipient, not the author.
func TestAPhotoPushCarriesAThumbnailTheRecipientCanFetch(t *testing.T) {
	app := newMediaApp(t)
	author := newUser(t, app, "ada@example.com")
	recipient := newUser(t, app, "bo@example.com")
	pair := newRecord(t, app, "pairs", map[string]any{})
	post := newRecord(t, app, "posts", map[string]any{
		"pair": pair.Id, "author": author.Id, "type": "photo", "media": "pear_abc123.jpg",
	})

	raw := mediaURLFor(app, post, recipient.Id)
	if raw == "" {
		t.Fatal("no media_url for a photo")
	}
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse %q: %v", raw, err)
	}
	if !strings.HasPrefix(raw, "https://peard.example/api/files/") || !strings.HasSuffix(u.Path, "/"+post.Id+"/pear_abc123.jpg") {
		t.Errorf("url = %s, want the post's file under the app URL", raw)
	}
	if got := u.Query().Get("thumb"); got != "512x512" {
		t.Errorf("thumb = %q, want 512x512", got)
	}
	holder, err := app.FindAuthRecordByToken(u.Query().Get("token"), core.TokenTypeFile)
	if err != nil {
		t.Fatalf("token is not a valid file token: %v", err)
	}
	if holder.Id != recipient.Id {
		t.Errorf("token belongs to %s, want the recipient %s", holder.Id, recipient.Id)
	}
}

func TestAMomentWithoutAPhotoCarriesNoURL(t *testing.T) {
	app := newMediaApp(t)
	author := newUser(t, app, "ada@example.com")
	recipient := newUser(t, app, "bo@example.com")
	pair := newRecord(t, app, "pairs", map[string]any{})
	post := newRecord(t, app, "posts", map[string]any{
		"pair": pair.Id, "author": author.Id, "type": "event", "event_kind": "beer",
	})

	if got := mediaURLFor(app, post, recipient.Id); got != "" {
		t.Errorf("media_url = %q for a moment with no photo", got)
	}
}

// With no public URL configured there is nothing to build a link from; the
// alert goes without a picture rather than with a broken one.
func TestWithoutAnAppURLThereIsNoPicture(t *testing.T) {
	app := newMediaApp(t)
	app.Settings().Meta.AppURL = ""
	author := newUser(t, app, "ada@example.com")
	recipient := newUser(t, app, "bo@example.com")
	pair := newRecord(t, app, "pairs", map[string]any{})
	post := newRecord(t, app, "posts", map[string]any{
		"pair": pair.Id, "author": author.Id, "type": "photo", "media": "pear_abc123.jpg",
	})

	if got := mediaURLFor(app, post, recipient.Id); got != "" {
		t.Errorf("media_url = %q with no app URL", got)
	}
}
