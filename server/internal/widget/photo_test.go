package widget_test

import (
	"encoding/base64"
	"encoding/json"
	"net/http/httptest"
	"net/url"
	"slices"
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/filesystem"
)

// onePixelPNG is a valid 1×1 PNG; PocketBase sniffs uploads against the
// field's allowed types.
const onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="

// feedThumb fetches the feed with extra query and returns the thumb size its
// photo link asks for.
func (w *feedWorld) feedThumb(t *testing.T, extra string) string {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/peard/widget/feed?token="+w.token+extra, nil)
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("feed: got %d, body %s", rec.Code, rec.Body.String())
	}
	var parsed struct {
		Post struct {
			MediaURL string `json:"media_url"`
		} `json:"post"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &parsed); err != nil {
		t.Fatalf("decode feed: %v", err)
	}
	link, err := url.Parse(parsed.Post.MediaURL)
	if err != nil || parsed.Post.MediaURL == "" {
		t.Fatalf("media_url = %q, want a link", parsed.Post.MediaURL)
	}
	return link.Query().Get("thumb")
}

func TestTheLargeWidgetAsksForASharperPhoto(t *testing.T) {
	w := newFeedWorld(t)
	raw, _ := base64.StdEncoding.DecodeString(onePixelPNG)
	file, err := filesystem.NewFileFromBytes(raw, "photo.png")
	if err != nil {
		t.Fatalf("build file: %v", err)
	}
	w.newRecord(t, "posts", map[string]any{
		"pair": w.pair.Id, "author": w.bob.Id, "type": "photo",
		"media": []*filesystem.File{file},
	})

	if got := w.feedThumb(t, ""); got != "512x512" {
		t.Errorf("default thumb = %q, want 512x512", got)
	}
	if got := w.feedThumb(t, "&photo=large"); got != "1024x1024" {
		t.Errorf("large thumb = %q, want 1024x1024", got)
	}

	// PocketBase serves only the sizes the field lists, and quietly sends the
	// original for any other — so a link to an undeclared size would still
	// "work", just not as a thumbnail.
	posts, _ := w.app.FindCollectionByNameOrId("posts")
	field, _ := posts.Fields.GetByName("media").(*core.FileField)
	if field == nil || !slices.Contains(field.Thumbs, "1024x1024") {
		t.Errorf("posts.media thumbs = %v, want 1024x1024 declared", field)
	}
}
