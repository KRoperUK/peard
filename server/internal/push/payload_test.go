package push

import (
	"testing"

	"github.com/pocketbase/pocketbase/core"
)

// pushWorld is two people in one connection, Bo with a phone to push to.
type pushWorld struct {
	app  core.App
	ada  *core.Record
	bo   *core.Record
	pair *core.Record
	apns *fakeAPNs
}

func newPushWorld(t *testing.T) pushWorld {
	t.Helper()
	app := newMediaApp(t)
	w := pushWorld{app: app, apns: installFakeAPNs(t, nil)}
	w.ada = newUser(t, app, "ada@example.com")
	w.bo = newUser(t, app, "bo@example.com")
	w.pair = newRecord(t, app, "pairs", map[string]any{})
	for _, u := range []*core.Record{w.ada, w.bo} {
		newRecord(t, app, "pair_members", map[string]any{"pair": w.pair.Id, "user": u.Id, "role": "member"})
	}
	for _, u := range []*core.Record{w.ada, w.bo} {
		newRecord(t, app, "devices", map[string]any{"user": u.Id, "platform": "ios", "push_token": u.Email() + "-device"})
	}
	return w
}

// onlyAlert is the one alert a test expects to have gone out.
func (w pushWorld) onlyAlert(t *testing.T) map[string]any {
	t.Helper()
	alerts := w.apns.alerts()
	if len(alerts) != 1 {
		t.Fatalf("sent %d alerts, want 1: %v", len(alerts), alerts)
	}
	return alerts[0]
}

// The app folds an alert for the connection on screen into that screen, and
// answers "me too" from the alert itself — neither of which it can do without
// being told which connection, and which moment, the alert is about.
func TestAMomentAlertNamesItsConnectionAndKind(t *testing.T) {
	w := newPushWorld(t)
	post := newRecord(t, w.app, "posts", map[string]any{
		"pair": w.pair.Id, "author": w.ada.Id, "type": "event", "event_kind": "beer",
	})

	notifyPairMembers(w.app, post)

	alert := w.onlyAlert(t)
	for key, want := range map[string]string{"post_id": post.Id, "pair_id": w.pair.Id, "event_kind": "beer"} {
		if got, _ := alert[key].(string); got != want {
			t.Errorf("%s = %q, want %q", key, got, want)
		}
	}
}

// A photo on its own is not a moment, so there is no kind to repeat.
func TestAPhotoAlertCarriesNoKind(t *testing.T) {
	w := newPushWorld(t)
	post := newRecord(t, w.app, "posts", map[string]any{
		"pair": w.pair.Id, "author": w.ada.Id, "type": "photo", "event_kind": "beer",
	})

	notifyPairMembers(w.app, post)

	alert := w.onlyAlert(t)
	if got, _ := alert["pair_id"].(string); got != w.pair.Id {
		t.Errorf("pair_id = %q, want %q", got, w.pair.Id)
	}
	if kind, present := alert["event_kind"]; present {
		t.Errorf("event_kind = %v on a photo, want none", kind)
	}
}

// A reaction lands on the reacted-to moment's screen, so it names the
// connection too.
func TestAReactionAlertNamesItsConnection(t *testing.T) {
	w := newPushWorld(t)
	post := newRecord(t, w.app, "posts", map[string]any{
		"pair": w.pair.Id, "author": w.ada.Id, "type": "event", "event_kind": "beer",
	})
	reaction := newRecord(t, w.app, "reactions", map[string]any{"post": post.Id, "user": w.bo.Id, "kind": "cheers"})

	notifyPostAuthor(w.app, reaction)

	alert := w.onlyAlert(t)
	for key, want := range map[string]string{"post_id": post.Id, "pair_id": w.pair.Id} {
		if got, _ := alert[key].(string); got != want {
			t.Errorf("%s = %q, want %q", key, got, want)
		}
	}
}
