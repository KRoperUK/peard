package push

import (
	"net/http"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/sideshow/apns2"
)

func deviceExists(t *testing.T, app core.App, token string) bool {
	t.Helper()
	d, err := app.FindFirstRecordByData("devices", "push_token", token)
	return err == nil && d != nil
}

// A token APNs has disowned is never going to work again, so its row goes
// rather than being retried on every moment for ever. Any other refusal leaves
// the device alone: a bad topic is the server's mistake, not the phone's.
func TestDeadDeviceTokensAreForgotten(t *testing.T) {
	app := newMediaApp(t)
	installFakeAPNs(t, map[string]fakeReply{
		"gone":  {http.StatusGone, apns2.ReasonUnregistered},
		"bad":   {http.StatusBadRequest, apns2.ReasonBadDeviceToken},
		"topic": {http.StatusBadRequest, apns2.ReasonBadTopic},
	})
	ada := newUser(t, app, "ada@example.com")
	pair := newRecord(t, app, "pairs", map[string]any{"name": "Flatmates"})
	newRecord(t, app, "pair_members", map[string]any{"pair": pair.Id, "user": ada.Id, "role": "member"})
	for i, token := range []string{"gone", "bad", "topic", "live"} {
		u := newUser(t, app, token+"@example.com")
		newRecord(t, app, "pair_members", map[string]any{"pair": pair.Id, "user": u.Id, "role": "member"})
		newRecord(t, app, "devices", map[string]any{"user": u.Id, "platform": "ios", "push_token": []string{"gone", "bad", "topic", "live"}[i]})
	}
	post := newRecord(t, app, "posts", map[string]any{
		"pair": pair.Id, "author": ada.Id, "type": "event", "event_kind": "beer",
	})

	notifyPairMembers(app, post)

	for token, want := range map[string]bool{"gone": false, "bad": false, "topic": true, "live": true} {
		if got := deviceExists(t, app, token); got != want {
			t.Errorf("device %q exists = %v, want %v", token, got, want)
		}
	}
}

func TestADeadTokenIsForgottenWhenAReactionFindsIt(t *testing.T) {
	app := newMediaApp(t)
	installFakeAPNs(t, map[string]fakeReply{"ada-device": {http.StatusGone, apns2.ReasonUnregistered}})
	ada := newUser(t, app, "ada@example.com")
	bo := newUser(t, app, "bo@example.com")
	pair := newRecord(t, app, "pairs", map[string]any{})
	for _, u := range []*core.Record{ada, bo} {
		newRecord(t, app, "pair_members", map[string]any{"pair": pair.Id, "user": u.Id, "role": "member"})
	}
	newRecord(t, app, "devices", map[string]any{"user": ada.Id, "platform": "ios", "push_token": "ada-device"})
	post := newRecord(t, app, "posts", map[string]any{"pair": pair.Id, "author": ada.Id, "type": "event", "event_kind": "beer"})
	reaction := newRecord(t, app, "reactions", map[string]any{"post": post.Id, "user": bo.Id, "kind": "cheers"})

	notifyPostAuthor(app, reaction)

	if deviceExists(t, app, "ada-device") {
		t.Fatal("the device APNs called unregistered is still there")
	}
}

// An activity whose token has died is over; the next photo starts a new one.
func TestADeadActivityTokenForgetsTheActivity(t *testing.T) {
	w := newDropWorld(t)
	installFakeAPNs(t, map[string]fakeReply{"bo-activity": {http.StatusGone, apns2.ReasonUnregistered}})
	row := w.activity(t, "bo-activity")
	photo := newRecord(t, w.app, "posts", map[string]any{"pair": w.pair.Id, "author": w.ada.Id, "type": "photo", "media": "p.jpg"})

	notifyPhotoDrop(w.app, photo, w.bo.Id, []*core.Record{w.boDevice}, "ada", "title", "body")

	if _, err := w.app.FindRecordById("live_activities", row.Id); err == nil {
		t.Fatal("the activity APNs called unregistered is still there")
	}
}

// A dead push-to-start token loses only that token: the device still takes
// ordinary notifications.
func TestADeadStartTokenIsClearedButTheDeviceKept(t *testing.T) {
	w := newDropWorld(t)
	installFakeAPNs(t, map[string]fakeReply{"bo-start": {http.StatusBadRequest, apns2.ReasonBadDeviceToken}})
	photo := newRecord(t, w.app, "posts", map[string]any{"pair": w.pair.Id, "author": w.ada.Id, "type": "photo", "media": "p.jpg"})

	notifyPhotoDrop(w.app, photo, w.bo.Id, []*core.Record{w.boDevice}, "ada", "title", "body")

	device, err := w.app.FindRecordById("devices", w.boDevice.Id)
	if err != nil {
		t.Fatalf("the device went with its start token: %v", err)
	}
	if got := device.GetString("activity_start_token"); got != "" {
		t.Fatalf("activity_start_token = %q, want it cleared", got)
	}
	if got := device.GetString("push_token"); got != "bo-device" {
		t.Fatalf("push_token = %q, want it kept", got)
	}
}

// The poster's request must not wait on Apple: with every APNs reply held, the
// post still saves, and the pushes go out once Apple answers.
func TestPostingDoesNotWaitForDelivery(t *testing.T) {
	app := newMediaApp(t)
	Register(app)
	apns := installFakeAPNs(t, nil)
	ada := newUser(t, app, "ada@example.com")
	bo := newUser(t, app, "bo@example.com")
	pair := newRecord(t, app, "pairs", map[string]any{})
	for _, u := range []*core.Record{ada, bo} {
		newRecord(t, app, "pair_members", map[string]any{"pair": pair.Id, "user": u.Id, "role": "member"})
	}
	newRecord(t, app, "devices", map[string]any{"user": bo.Id, "platform": "ios", "push_token": "bo-device"})
	apns.holdReplies()

	col, _ := app.FindCollectionByNameOrId("posts")
	post := core.NewRecord(col)
	post.Set("pair", pair.Id)
	post.Set("author", ada.Id)
	post.Set("type", "event")
	post.Set("event_kind", "beer")
	saved := make(chan error, 1)
	go func() { saved <- app.SaveNoValidate(post) }()
	select {
	case err := <-saved:
		if err != nil {
			t.Fatalf("save post: %v", err)
		}
	case <-time.After(5 * time.Second):
		apns.release()
		<-saved
		t.Fatal("saving the post waited for APNs")
	}

	apns.release()
	waitForDeliveries()
	if got := apns.sentTo(); !slices.Equal(got, []string{"bo-device", "bo-device"}) {
		t.Fatalf("sent to %v, want bo-device's alert and background push", got)
	}
}

// A fan-out that panics is logged and the slot it held is given back, so one bad
// post neither takes the server down nor starves the posts after it.
func TestADeliveryThatPanicsIsContained(t *testing.T) {
	app := newMediaApp(t)
	deliverInBackground(app, "test", func() { panic("boom") })
	waitForDeliveries()

	var ran atomic.Bool
	for range maxConcurrentDeliveries {
		deliverInBackground(app, "test", func() {})
	}
	deliverInBackground(app, "test", func() { ran.Store(true) })
	waitForDeliveries()
	if !ran.Load() {
		t.Fatal("deliveries stopped running after a panic")
	}
}

// However many posts arrive at once, no more than the cap fan out together.
func TestDeliveriesAreCapped(t *testing.T) {
	app := newMediaApp(t)
	release := make(chan struct{})
	var running, peak atomic.Int32
	for range maxConcurrentDeliveries * 3 {
		deliverInBackground(app, "test", func() {
			now := running.Add(1)
			for {
				old := peak.Load()
				if now <= old || peak.CompareAndSwap(old, now) {
					break
				}
			}
			<-release
			running.Add(-1)
		})
	}
	deadline := time.Now().Add(5 * time.Second)
	for running.Load() < maxConcurrentDeliveries && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	time.Sleep(20 * time.Millisecond)
	close(release)
	waitForDeliveries()
	if got := peak.Load(); got != maxConcurrentDeliveries {
		t.Fatalf("peak concurrent deliveries = %d, want exactly the cap %d", got, maxConcurrentDeliveries)
	}
}
