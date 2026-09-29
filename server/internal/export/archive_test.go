package export_test

import (
	"archive/zip"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// exportZip fetches alice's export with ?media=zip and opens it.
func (w *exportWorld) exportZip(t *testing.T) (*httptest.ResponseRecorder, map[string][]byte) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/api/peard/export?media=zip", nil)
	req.Header.Set("Authorization", w.aliceTok)
	rec := httptest.NewRecorder()
	w.mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("zip export: status %d, body %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.Bytes()
	zr, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
	if err != nil {
		t.Fatalf("open zip: %v", err)
	}
	files := map[string][]byte{}
	for _, f := range zr.File {
		r, err := f.Open()
		if err != nil {
			t.Fatalf("open %s: %v", f.Name, err)
		}
		data, _ := io.ReadAll(r)
		r.Close()
		files[f.Name] = data
	}
	return rec, files
}

func TestZipExportHoldsThePhotosTheJSONPointsAt(t *testing.T) {
	w := newExportWorld(t)
	rec, files := w.exportZip(t)

	if ct := rec.Header().Get("Content-Type"); ct != "application/zip" {
		t.Errorf("Content-Type = %q, want application/zip", ct)
	}
	if cd := rec.Header().Get("Content-Disposition"); !strings.Contains(cd, "attachment") || !strings.Contains(cd, ".zip") {
		t.Errorf("Content-Disposition = %q, want an attachment named .zip", cd)
	}

	raw, ok := files["export.json"]
	if !ok {
		t.Fatalf("no export.json in %v", keys(files))
	}
	var p struct {
		exportPayload
		MissingMedia []string `json:"missing_media"`
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		t.Fatalf("decode export.json: %v", err)
	}
	if len(p.MissingMedia) != 0 {
		t.Errorf("missing_media = %v, want none", p.MissingMedia)
	}
	if strings.Contains(p.MediaNote, "30 minutes") {
		t.Errorf("media_note still talks about expiring links: %q", p.MediaNote)
	}

	png, _ := base64.StdEncoding.DecodeString(onePixelPNG)

	var photoPath string
	for _, m := range p.Moments {
		if m["id"] == w.alicePhoto.Id {
			photoPath, _ = m["media_path"].(string)
			if _, has := m["media_url"]; has {
				t.Errorf("zip moment still carries media_url: %v", m)
			}
		} else if _, has := m["media_path"]; has {
			t.Errorf("moment %v has no photo but carries media_path", m["id"])
		}
	}
	if photoPath == "" {
		t.Fatalf("photo moment has no media_path: %v", p.Moments)
	}
	if !bytes.Equal(files[photoPath], png) {
		t.Errorf("%s in the zip is %d bytes, want the stored photo", photoPath, len(files[photoPath]))
	}

	avatarPath, _ := p.Profile["avatar_path"].(string)
	if avatarPath == "" || !bytes.Equal(files[avatarPath], png) {
		t.Errorf("avatar_path %q does not name the stored avatar in %v", avatarPath, keys(files))
	}
	if _, has := p.Profile["avatar_url"]; has {
		t.Errorf("zip profile still carries avatar_url")
	}
	if strings.Contains(string(raw), "token=") {
		t.Errorf("export.json carries a file token")
	}
}

func TestZipExportRequiresAuth(t *testing.T) {
	w := newExportWorld(t)
	status, _ := w.get(t, "/api/peard/export?media=zip", "")
	if status != http.StatusUnauthorized {
		t.Errorf("anonymous zip export: status %d, want 401", status)
	}
}

func TestZipExportNeverContainsAnOutsidersData(t *testing.T) {
	w := newExportWorld(t)
	_, files := w.exportZip(t)
	body := string(files["export.json"])
	for _, id := range []string{w.carol.Id} {
		if strings.Contains(body, id) {
			t.Errorf("zip export mentions outsider %s", id)
		}
	}
	for name := range files {
		if name != "export.json" && !strings.HasPrefix(name, "photos/"+w.alicePhoto.Id+"-") && !strings.HasPrefix(name, "avatar/") {
			t.Errorf("unexpected file in the zip: %s", name)
		}
	}
}

func keys(m map[string][]byte) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
