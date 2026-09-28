package push

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
)

type dropWorld struct {
	app              core.App
	ada, bo, mallory *core.Record
	pair             *core.Record
	boDevice         *core.Record
}

func newDropWorld(t *testing.T) *dropWorld {
	t.Helper()
	app := newMediaApp(t)
	Register(app)
	w := &dropWorld{app: app}
	w.ada = newUser(t, app, "ada@example.com")
	w.bo = newUser(t, app, "bo@example.com")
	w.mallory = newUser(t, app, "mallory@example.com")
	w.pair = newRecord(t, app, "pairs", map[string]any{"name": "Flatmates"})
	for _, u := range []*core.Record{w.ada, w.bo} {
		newRecord(t, app, "pair_members", map[string]any{"pair": w.pair.Id, "user": u.Id, "role": "member"})
	}
	w.boDevice = newRecord(t, app, "devices", map[string]any{
		"user": w.bo.Id, "platform": "ios", "push_token": "bo-device", "activity_start_token": "bo-start",
	})
	return w
}

func (w *dropWorld) activity(t *testing.T, token string) *core.Record {
	t.Helper()
	col, _ := w.app.FindCollectionByNameOrId("live_activities")
	r := core.NewRecord(col)
	r.Set("user", w.bo.Id)
	r.Set("pair", w.pair.Id)
	r.Set("push_token", token)
	if err := w.app.Save(r); err != nil {
		t.Fatalf("save live activity: %v", err)
	}
	return r
}

// MARK: start or update

func TestTheFirstPhotoStartsAnActivity(t *testing.T) {
	w := newDropWorld(t)

	targets := photoDropTargets(w.app, w.bo.Id, w.pair.Id, []*core.Record{w.boDevice}, time.Now())

	if len(targets) != 1 || !targets[0].start || targets[0].token != "bo-start" {
		t.Fatalf("targets = %+v, want one start with the push-to-start token", targets)
	}
}

// Starting another would put two on the Lock Screen.
func TestARunningActivityIsUpdatedNotStartedAgain(t *testing.T) {
	w := newDropWorld(t)
	w.activity(t, "bo-activity")

	targets := photoDropTargets(w.app, w.bo.Id, w.pair.Id, []*core.Record{w.boDevice}, time.Now())

	if len(targets) != 1 || targets[0].start || targets[0].token != "bo-activity" {
		t.Fatalf("targets = %+v, want one update to the running activity", targets)
	}
}

func TestALapsedActivityIsForgottenAndANewOneStarted(t *testing.T) {
	w := newDropWorld(t)
	row := w.activity(t, "bo-old")

	later := time.Now().Add(photoDropWindow + time.Minute)
	targets := photoDropTargets(w.app, w.bo.Id, w.pair.Id, []*core.Record{w.boDevice}, later)

	if len(targets) != 1 || !targets[0].start {
		t.Fatalf("targets = %+v, want a fresh start", targets)
	}
	if _, err := w.app.FindRecordById("live_activities", row.Id); err == nil {
		t.Error("the lapsed activity's row is still there")
	}
}

func TestADeviceWithoutLiveActivitiesGetsNothing(t *testing.T) {
	w := newDropWorld(t)
	w.boDevice.Set("activity_start_token", "")

	if targets := photoDropTargets(w.app, w.bo.Id, w.pair.Id, []*core.Record{w.boDevice}, time.Now()); len(targets) != 0 {
		t.Fatalf("targets = %+v, want none", targets)
	}
}

// MARK: the window

// The server decides how long a drop lasts, not the phone.
func TestRegisteringAnActivityGivesItTheWindow(t *testing.T) {
	w := newDropWorld(t)

	row := w.activity(t, "bo-activity")

	got := row.GetDateTime("expires").Time()
	if d := time.Until(got); d < photoDropWindow-time.Minute || d > photoDropWindow+time.Minute {
		t.Errorf("expires in %s, want about %s", d, photoDropWindow)
	}
}

func TestAClientCannotExtendTheWindow(t *testing.T) {
	w := newDropWorld(t)
	row := w.activity(t, "bo-activity")
	before := row.GetDateTime("expires").String()

	row.Set("expires", time.Now().Add(24*time.Hour))
	if err := w.app.Save(row); err != nil {
		t.Fatalf("save: %v", err)
	}

	fresh, _ := w.app.FindRecordById("live_activities", row.Id)
	if got := fresh.GetDateTime("expires").String(); got != before {
		t.Errorf("expires moved from %s to %s", before, got)
	}
}

// MARK: who may register

func TestOnlyAMemberCanRegisterAnActivityForAConnection(t *testing.T) {
	w := newDropWorld(t)
	col, _ := w.app.FindCollectionByNameOrId("live_activities")

	check := func(user *core.Record) bool {
		row := core.NewRecord(col)
		row.Set("user", user.Id)
		row.Set("pair", w.pair.Id)
		row.Set("push_token", "t-"+user.Id)
		if err := w.app.Save(row); err != nil {
			t.Fatalf("save: %v", err)
		}
		defer w.app.Delete(row)
		ok, err := w.app.CanAccessRecord(row, &core.RequestInfo{Auth: user}, col.CreateRule)
		if err != nil {
			t.Fatalf("rule: %v", err)
		}
		return ok
	}

	if !check(w.bo) {
		t.Error("a member was refused")
	}
	if check(w.mallory) {
		t.Error("somebody outside the connection registered for its photos")
	}
}

// MARK: payloads

func TestAStartCarriesAttributesAndASilentAlert(t *testing.T) {
	now := time.Unix(1_790_000_000, 0)
	content := map[string]interface{}{"postID": "p1", "authorName": "Ada", "caption": "", "count": 1, "updatedAt": float64(now.Unix())}

	aps := apsOf(t, photoDropPayload(true, content, "pair1", "Flatmates", "🍐 Fresh pear from Ada", "", now))

	if aps["event"] != "start" || aps["attributes-type"] != photoDropAttributesType {
		t.Fatalf("aps = %v, want a start of %s", aps, photoDropAttributesType)
	}
	attrs, _ := aps["attributes"].(map[string]interface{})
	if attrs["pairID"] != "pair1" || attrs["title"] != "Flatmates" {
		t.Errorf("attributes = %v", attrs)
	}
	if aps["alert"] == nil {
		t.Error("a start must carry an alert")
	}
	if _, ok := aps["sound"]; ok {
		t.Error("the start made a sound; the photo notification already did")
	}
	if int64(aps["stale-date"].(float64)) != now.Add(photoDropWindow).Unix() {
		t.Errorf("stale-date = %v, want the end of the window", aps["stale-date"])
	}
}

func TestAnUpdateCarriesOnlyTheNewState(t *testing.T) {
	now := time.Unix(1_790_000_000, 0)
	content := map[string]interface{}{"postID": "p2", "authorName": "Bo", "caption": "look", "count": 2, "updatedAt": float64(now.Unix())}

	aps := apsOf(t, photoDropPayload(false, content, "pair1", "Flatmates", "x", "y", now))

	if aps["event"] != "update" {
		t.Fatalf("event = %v, want update", aps["event"])
	}
	if aps["attributes"] != nil || aps["alert"] != nil {
		t.Errorf("an update carried attributes or an alert: %v", aps)
	}
	state, _ := aps["content-state"].(map[string]interface{})
	if state["count"].(float64) != 2 || state["postID"] != "p2" {
		t.Errorf("content-state = %v", state)
	}
}

func TestTheCountIsPhotosInTheWindow(t *testing.T) {
	w := newDropWorld(t)
	old := newRecord(t, w.app, "posts", map[string]any{"pair": w.pair.Id, "author": w.ada.Id, "type": "photo", "media": "a.jpg"})
	stamp := time.Now().Add(-2 * photoDropWindow).UTC().Format("2006-01-02 15:04:05.000Z")
	if _, err := w.app.DB().NewQuery("UPDATE {{posts}} SET [[created]] = {:t} WHERE [[id]] = {:id}").
		Bind(map[string]any{"t": stamp, "id": old.Id}).Execute(); err != nil {
		t.Fatalf("backdate: %v", err)
	}
	newRecord(t, w.app, "posts", map[string]any{"pair": w.pair.Id, "author": w.ada.Id, "type": "photo", "media": "b.jpg"})
	latest := newRecord(t, w.app, "posts", map[string]any{"pair": w.pair.Id, "author": w.bo.Id, "type": "photo", "media": "c.jpg", "note": "hi"})
	newRecord(t, w.app, "posts", map[string]any{"pair": w.pair.Id, "author": w.bo.Id, "type": "event", "event_kind": "beer"})

	content := photoDropContent(w.app, latest, "Bo", time.Now())

	if content["count"] != 2 {
		t.Errorf("count = %v, want the 2 photos inside the window", content["count"])
	}
	if content["caption"] != "hi" || content["postID"] != latest.Id {
		t.Errorf("content = %v", content)
	}
}

func apsOf(t *testing.T, p interface{ MarshalJSON() ([]byte, error) }) map[string]interface{} {
	t.Helper()
	raw, err := p.MarshalJSON()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var body struct {
		APS map[string]interface{} `json:"aps"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return body.APS
}

// A photo does move the window on — it is the one thing that should.
func TestAPhotoPushesTheWindowOn(t *testing.T) {
	w := newDropWorld(t)
	row := w.activity(t, "bo-activity")
	if _, err := w.app.DB().NewQuery("UPDATE {{live_activities}} SET [[expires]] = {:t} WHERE [[id]] = {:id}").
		Bind(map[string]any{"t": time.Now().Add(time.Minute).UTC().Format("2006-01-02 15:04:05.000Z"), "id": row.Id}).Execute(); err != nil {
		t.Fatalf("shorten: %v", err)
	}
	fresh, _ := w.app.FindRecordById("live_activities", row.Id)

	fresh.Set("expires", time.Now().Add(photoDropWindow))
	if err := w.app.SaveWithContext(context.WithValue(context.Background(), extendingWindow{}, true), fresh); err != nil {
		t.Fatalf("save: %v", err)
	}

	after, _ := w.app.FindRecordById("live_activities", row.Id)
	if d := time.Until(after.GetDateTime("expires").Time()); d < photoDropWindow-time.Minute {
		t.Errorf("window now ends in %s, want about %s", d, photoDropWindow)
	}
}
