package health_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"peard/internal/health"
	_ "peard/migrations"
)

// Only a superuser may read it: it says which jobs are failing and whether push
// is configured, which is nobody else's business.
func TestOnlySuperusersCanReadTheStatus(t *testing.T) {
	dir, err := os.MkdirTemp("", "peard-health-test-*")
	if err != nil {
		t.Fatal(err)
	}
	app, err := tests.NewTestApp(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { app.Cleanup(); os.RemoveAll(dir) })
	health.Register(app)

	users, _ := app.FindCollectionByNameOrId("users")
	user := core.NewRecord(users)
	user.SetEmail("ada@example.com")
	user.SetPassword("Password123!")
	if err := app.Save(user); err != nil {
		t.Fatal(err)
	}
	userToken, _ := user.NewAuthToken()

	supers, _ := app.FindCollectionByNameOrId(core.CollectionNameSuperusers)
	admin := core.NewRecord(supers)
	admin.SetEmail("admin@example.com")
	admin.SetPassword("Password123!")
	if err := app.Save(admin); err != nil {
		t.Fatal(err)
	}
	adminToken, _ := admin.NewAuthToken()

	router, err := apis.NewRouter(app)
	if err != nil {
		t.Fatal(err)
	}
	var mux http.Handler
	ev := &core.ServeEvent{App: app, Router: router}
	if err := app.OnServe().Trigger(ev, func(e *core.ServeEvent) error {
		m, err := e.Router.BuildMux()
		mux = m
		return err
	}); err != nil {
		t.Fatal(err)
	}
	get := func(token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, "/api/peard/admin/status", nil)
		if token != "" {
			r.Header.Set("Authorization", token)
		}
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, r)
		return w
	}

	if w := get(""); w.Code == http.StatusOK {
		t.Errorf("a guest got %d", w.Code)
	}
	if w := get(userToken); w.Code == http.StatusOK {
		t.Errorf("a signed-in user got %d", w.Code)
	}
	w := get(adminToken)
	if w.Code != http.StatusOK {
		t.Fatalf("a superuser got %d: %s", w.Code, w.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || body["push"] == nil || !strings.Contains(w.Body.String(), `"jobs"`) {
		t.Fatalf("status body %q: %v", w.Body.String(), err)
	}
}
