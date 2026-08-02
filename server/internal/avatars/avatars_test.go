package avatars

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	_ "peard/migrations"
)

// These drive the real router against a real database with Pear'd's full schema,
// because the claims worth checking are not about the handler's arithmetic:
//
//   - an uploaded avatar has to be servable to *other* members, which depends on
//     the file field being unprotected and is invisible to a unit test;
//   - the thumbnails the migration declares have to actually resolve, or the
//     connection rail silently pulls full-size photos;
//   - a non-member must not be able to reface somebody else's group.
//
// The router is built the same way tests.ApiScenario builds it, but by hand: the
// auth token only exists after seeding, and the scenario reads its headers from a
// map it captured before the factory ran.

// onePixelPNG is a valid 1×1 PNG. Real image bytes matter: PocketBase sniffs the
// content type from the payload, so a text file named .png is rejected — and the
// thumb generation would fail on anything undecodable.
const onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="

type harness struct {
	app    *tests.TestApp
	mux    http.Handler
	member *core.Record
	// outsider belongs to no connection, so it can only ever act on itself.
	outsider      *core.Record
	pair          *core.Record
	memberToken   string
	outsiderToken string
}

func newHarness(t *testing.T) *harness {
	t.Helper()

	dir, err := os.MkdirTemp("", "peard-avatars-test-*")
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

	Register(app)

	h := &harness{app: app}
	h.seed(t)

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
		h.mux = mux
		return nil
	}); err != nil {
		t.Fatalf("build mux: %v", err)
	}
	return h
}

func (h *harness) seed(t *testing.T) {
	t.Helper()

	usersCol, err := h.app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("users collection: %v", err)
	}
	newUser := func(email string) (*core.Record, string) {
		r := core.NewRecord(usersCol)
		r.SetEmail(email)
		r.SetVerified(true)
		r.SetPassword("Password123!")
		if err := h.app.Save(r); err != nil {
			t.Fatalf("save user %s: %v", email, err)
		}
		token, err := r.NewAuthToken()
		if err != nil {
			t.Fatalf("auth token for %s: %v", email, err)
		}
		return r, token
	}
	h.member, h.memberToken = newUser("member@example.com")
	h.outsider, h.outsiderToken = newUser("outsider@example.com")

	pairsCol, err := h.app.FindCollectionByNameOrId("pairs")
	if err != nil {
		t.Fatalf("pairs collection: %v", err)
	}
	h.pair = core.NewRecord(pairsCol)
	h.pair.Set("name", "Flatmates")
	if err := h.app.Save(h.pair); err != nil {
		t.Fatalf("save pair: %v", err)
	}

	membersCol, err := h.app.FindCollectionByNameOrId("pair_members")
	if err != nil {
		t.Fatalf("pair_members collection: %v", err)
	}
	m := core.NewRecord(membersCol)
	m.Set("pair", h.pair.Id)
	m.Set("user", h.member.Id)
	m.Set("role", "owner")
	if err := h.app.Save(m); err != nil {
		t.Fatalf("save membership: %v", err)
	}
}

// do issues a request through the real mux. An empty token sends no
// Authorization header at all, which is how a file fetch from another device
// arrives.
func (h *harness) do(t *testing.T, method, url, token, contentType string, body []byte) (int, string) {
	t.Helper()

	var reader *bytes.Reader
	if body == nil {
		reader = bytes.NewReader(nil)
	} else {
		reader = bytes.NewReader(body)
	}
	req := httptest.NewRequest(method, url, reader)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if token != "" {
		req.Header.Set("Authorization", token)
	}
	recorder := httptest.NewRecorder()
	h.mux.ServeHTTP(recorder, req)
	return recorder.Code, recorder.Body.String()
}

// avatarUpload builds a multipart body carrying the PNG plus any extra fields.
func avatarUpload(t *testing.T, fields map[string]string, fileField string) (string, []byte) {
	t.Helper()

	raw, err := base64.StdEncoding.DecodeString(onePixelPNG)
	if err != nil {
		t.Fatalf("decode png: %v", err)
	}

	var buffer bytes.Buffer
	writer := multipart.NewWriter(&buffer)
	for key, value := range fields {
		if err := writer.WriteField(key, value); err != nil {
			t.Fatalf("write field %s: %v", key, err)
		}
	}
	if fileField != "" {
		part, err := writer.CreateFormFile(fileField, "avatar.png")
		if err != nil {
			t.Fatalf("create form file: %v", err)
		}
		if _, err := part.Write(raw); err != nil {
			t.Fatalf("write png: %v", err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close writer: %v", err)
	}
	return writer.FormDataContentType(), buffer.Bytes()
}

func decodeAvatar(t *testing.T, body string) string {
	t.Helper()

	var payload struct {
		Avatar string `json:"avatar"`
	}
	if err := json.Unmarshal([]byte(body), &payload); err != nil {
		t.Fatalf("decode response %q: %v", body, err)
	}
	return payload.Avatar
}

func TestProfileAvatarNeedsAFileTokenToRead(t *testing.T) {
	h := newHarness(t)

	contentType, body := avatarUpload(t, nil, "avatar")
	status, response := h.do(t, http.MethodPost, "/api/peard/profile/avatar", h.memberToken, contentType, body)
	if status != http.StatusOK {
		t.Fatalf("upload status = %d, want 200; body %s", status, response)
	}
	filename := decodeAvatar(t, response)
	if filename == "" {
		t.Fatalf("response carried no avatar filename: %s", response)
	}
	if !strings.HasSuffix(filename, ".png") {
		t.Errorf("avatar filename = %q, want a .png", filename)
	}

	// This test used to assert the opposite — that the file was servable with
	// no auth at all — because `users.avatar` was an unprotected field and the
	// avatar migration reasoned that protecting it would hide it from the
	// people who need it. It did hide the *record*; 1786233600 separates the
	// two, so the record stays private and the file opens to connection
	// members.
	path := "/api/files/users/" + h.member.Id + "/" + filename
	if status, response := h.do(t, http.MethodGet, path, "", "", nil); status != http.StatusNotFound {
		t.Errorf("unauthenticated file fetch = %d, want 404; body %s", status, response)
	}

	// The owner, with a token, still gets it — and so does the thumb, or the
	// rail pulls full-size photos.
	token := fileToken(t, h, h.memberToken)
	if status, response := h.do(t, http.MethodGet, path+"?token="+token, "", "", nil); status != http.StatusOK {
		t.Errorf("file fetch with a token = %d, want 200; body %s", status, response)
	}
	if status, response := h.do(t, http.MethodGet, path+"?thumb=128x128&token="+token, "", "", nil); status != http.StatusOK {
		t.Errorf("thumb fetch with a token = %d, want 200; body %s", status, response)
	}
}

// fileToken mints a short-lived token for the given session, which is what a
// protected file is served against.
func fileToken(t *testing.T, h *harness, authToken string) string {
	t.Helper()
	status, response := h.do(t, http.MethodPost, "/api/files/token", authToken, "application/json", []byte("{}"))
	if status != http.StatusOK {
		t.Fatalf("file token status = %d; body %s", status, response)
	}
	var payload struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal([]byte(response), &payload); err != nil {
		t.Fatalf("decode file token %q: %v", response, err)
	}
	return payload.Token
}

func TestProfileAvatarDeleteClearsTheField(t *testing.T) {
	h := newHarness(t)

	contentType, body := avatarUpload(t, nil, "avatar")
	if status, response := h.do(t, http.MethodPost, "/api/peard/profile/avatar", h.memberToken, contentType, body); status != http.StatusOK {
		t.Fatalf("upload status = %d, want 200; body %s", status, response)
	}

	status, response := h.do(t, http.MethodDelete, "/api/peard/profile/avatar", h.memberToken, "", nil)
	if status != http.StatusOK {
		t.Fatalf("delete status = %d, want 200; body %s", status, response)
	}
	if filename := decodeAvatar(t, response); filename != "" {
		t.Errorf("avatar after delete = %q, want empty", filename)
	}

	stored, err := h.app.FindRecordById("users", h.member.Id)
	if err != nil {
		t.Fatalf("reload user: %v", err)
	}
	if got := stored.GetString("avatar"); got != "" {
		t.Errorf("stored avatar = %q, want empty", got)
	}
}

func TestProfileAvatarRequiresAFile(t *testing.T) {
	h := newHarness(t)

	contentType, body := avatarUpload(t, map[string]string{"note": "no file here"}, "")
	status, response := h.do(t, http.MethodPost, "/api/peard/profile/avatar", h.memberToken, contentType, body)
	if status != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body %s", status, response)
	}
}

func TestProfileAvatarRequiresAuth(t *testing.T) {
	h := newHarness(t)

	contentType, body := avatarUpload(t, nil, "avatar")
	status, response := h.do(t, http.MethodPost, "/api/peard/profile/avatar", "", contentType, body)
	if status != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401; body %s", status, response)
	}
}

func TestConnectionAvatarAcceptsAnyMember(t *testing.T) {
	h := newHarness(t)

	contentType, body := avatarUpload(t, map[string]string{"pair": h.pair.Id}, "avatar")
	status, response := h.do(t, http.MethodPost, "/api/peard/connections/avatar", h.memberToken, contentType, body)
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200; body %s", status, response)
	}
	filename := decodeAvatar(t, response)
	if filename == "" {
		t.Fatalf("response carried no avatar filename: %s", response)
	}

	// `pairs.avatar` is protected too, and `pairs.ViewRule` already said the
	// right thing — a member may read it, nobody else may.
	path := "/api/files/pairs/" + h.pair.Id + "/" + filename
	if status, response := h.do(t, http.MethodGet, path+"?thumb=128x128", "", "", nil); status != http.StatusNotFound {
		t.Errorf("group thumb without a token = %d, want 404; body %s", status, response)
	}
	token := fileToken(t, h, h.memberToken)
	if status, response := h.do(t, http.MethodGet, path+"?thumb=128x128&token="+token, "", "", nil); status != http.StatusOK {
		t.Errorf("group thumb fetch = %d, want 200; body %s", status, response)
	}

	status, response = h.do(t, http.MethodDelete, "/api/peard/connections/avatar?pair="+h.pair.Id, h.memberToken, "", nil)
	if status != http.StatusOK {
		t.Fatalf("delete status = %d, want 200; body %s", status, response)
	}
	if filename := decodeAvatar(t, response); filename != "" {
		t.Errorf("avatar after delete = %q, want empty", filename)
	}
}

func TestConnectionAvatarRejectsNonMembers(t *testing.T) {
	h := newHarness(t)

	contentType, body := avatarUpload(t, map[string]string{"pair": h.pair.Id}, "avatar")
	status, response := h.do(t, http.MethodPost, "/api/peard/connections/avatar", h.outsiderToken, contentType, body)
	if status != http.StatusForbidden {
		t.Fatalf("status = %d, want 403; body %s", status, response)
	}

	stored, err := h.app.FindRecordById("pairs", h.pair.Id)
	if err != nil {
		t.Fatalf("reload pair: %v", err)
	}
	if got := stored.GetString("avatar"); got != "" {
		t.Errorf("pair avatar = %q, want empty — a non-member changed it", got)
	}
}

func TestConnectionAvatarRequiresAPair(t *testing.T) {
	h := newHarness(t)

	contentType, body := avatarUpload(t, nil, "avatar")
	status, response := h.do(t, http.MethodPost, "/api/peard/connections/avatar", h.memberToken, contentType, body)
	if status != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body %s", status, response)
	}
}
