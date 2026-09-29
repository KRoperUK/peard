package push

import (
	"context"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/payload"

	"peard/internal/health"
)

// Photo drops: a Live Activity on the Lock Screen and in the Dynamic Island
// while a connection is sharing photos.
//
// The first photo in a connection *starts* an activity on each member's device
// with its push-to-start token (`devices.activity_start_token`, iOS 17.2+). The
// app then registers that activity's own update token in `live_activities`, and
// photos in the next thirty minutes *update* it — latest photographer, caption,
// and how many have arrived. Each update pushes the window on; once it lapses
// the activity goes stale on the device and the next photo starts a new one.
//
// The activity cannot fetch the photo itself — its views have no network — so
// it shows the picture only if the notification service extension has already
// saved it to the App Group, keyed by `post_id`.

// photoDropWindow is how long an activity stays live after its last photo.
const photoDropWindow = 30 * time.Minute

// photoDropAttributesType is the Swift type name ActivityKit decodes a start
// push into; see PeardCore's PhotoDropAttributes.
const photoDropAttributesType = "PhotoDropAttributes"

// liveTarget is one Live Activity push to make.
type liveTarget struct {
	token  string
	start  bool
	record *core.Record // the live_activities row an update goes to; nil for a start
	device *core.Record // the device a start goes to; nil for an update
}

// photoDropTargets decides, for one recipient in one connection, whether to
// update activities already running or to start one on each of their devices.
//
// Updating wins when there is anything to update: starting a second activity
// for a connection that already has one would put two on the Lock Screen.
// Expired rows are deleted on the way past.
func photoDropTargets(app core.App, userID, pairID string, devices []*core.Record, now time.Time) []liveTarget {
	var targets []liveTarget
	rows, _ := app.FindRecordsByFilter("live_activities",
		"user = {:user} && pair = {:pair}", "", 20, 0,
		dbx.Params{"user": userID, "pair": pairID})
	for _, row := range rows {
		if expires := row.GetDateTime("expires"); expires.IsZero() || expires.Time().Before(now) {
			_ = app.Delete(row)
			continue
		}
		if token := row.GetString("push_token"); token != "" {
			targets = append(targets, liveTarget{token: token, record: row})
		}
	}
	if len(targets) > 0 {
		return targets
	}
	for _, d := range devices {
		if token := d.GetString("activity_start_token"); token != "" {
			targets = append(targets, liveTarget{token: token, start: true, device: d})
		}
	}
	return targets
}

// photoDropContent is the activity's content state. Keys match
// PhotoDropAttributes.ContentState; `updatedAt` is Unix seconds because
// ActivityKit's decoder reads a bare Date as seconds since 2001.
func photoDropContent(app core.App, post *core.Record, authorName string, now time.Time) map[string]interface{} {
	since := now.Add(-photoDropWindow).UTC().Format("2006-01-02 15:04:05.000Z")
	photos, _ := app.FindRecordsByFilter("posts",
		"pair = {:pair} && media != '' && created >= {:since}", "", 50, 0,
		dbx.Params{"pair": post.GetString("pair"), "since": since})
	count := len(photos)
	if count == 0 {
		count = 1
	}
	return map[string]interface{}{
		"postID":     post.Id,
		"authorName": authorName,
		"caption":    post.GetString("note"),
		"count":      count,
		"updatedAt":  float64(now.Unix()),
	}
}

// photoDropPayload builds a start or update push. A start must carry an alert —
// ActivityKit requires one — but no sound: the ordinary photo notification
// already made one, and two chimes for one photo reads as two photos.
func photoDropPayload(start bool, content map[string]interface{}, pairID, title, alertTitle, alertBody string, now time.Time) *payload.Payload {
	p := payload.NewPayload().
		SetTimestamp(now.Unix()).
		SetContentState(content).
		SetStaleDate(now.Add(photoDropWindow).Unix()).
		RelevanceScore(50)
	if start {
		p.SetEvent("start").
			SetAttributesType(photoDropAttributesType).
			SetAttributes(map[string]interface{}{"pairID": pairID, "title": title}).
			AlertTitle(alertTitle).
			AlertBody(alertBody)
	} else {
		p.SetEvent(payload.LiveActivityEventUpdate)
	}
	return p
}

// notifyPhotoDrop sends the Live Activity pushes for a new photo to one
// recipient, and pushes the window on for every activity it updates.
func notifyPhotoDrop(app core.App, post *core.Record, recipientID string, devices []*core.Record, authorName, alertTitle, alertBody string) {
	if n == nil || post.GetString("media") == "" {
		return
	}
	now := time.Now()
	pairID := post.GetString("pair")
	targets := photoDropTargets(app, recipientID, pairID, devices, now)
	if len(targets) == 0 {
		return
	}
	content := photoDropContent(app, post, authorName, now)
	title := photoDropTitle(app, pairID, authorName)
	for _, t := range targets {
		if n.sendLive(t.token, photoDropPayload(t.start, content, pairID, title, alertTitle, alertBody, now)) {
			forgetActivityToken(app, t)
			continue
		}
		if t.record != nil {
			t.record.Set("expires", now.Add(photoDropWindow))
			_ = app.SaveWithContext(context.WithValue(context.Background(), extendingWindow{}, true), t.record)
		}
	}
}

// forgetActivityToken drops a Live Activity token APNs has disowned. A dead
// update token means the activity has gone, so its row goes. A dead
// push-to-start token only clears that token: the device's ordinary push token
// is a different thing and may be fine.
func forgetActivityToken(app core.App, t liveTarget) {
	var err error
	switch {
	case t.record != nil:
		err = app.Delete(t.record)
	case t.device != nil:
		t.device.Set("activity_start_token", "")
		err = app.Save(t.device)
	}
	if err != nil {
		app.Logger().Error("push: could not forget a dead live activity token", "start", t.start, "error", err)
	}
}

// photoDropTitle names the activity: the connection's name when it has one,
// otherwise the other person in a pair — what the rail calls it.
func photoDropTitle(app core.App, pairID, authorName string) string {
	if pair, err := app.FindRecordById("pairs", pairID); err == nil {
		if name := pair.GetString("name"); name != "" {
			return name
		}
	}
	return authorName
}

// extendingWindow marks a save that is a photo pushing an activity's window on,
// which the update hook otherwise refuses.
type extendingWindow struct{}

// stampActivityExpiry gives a newly registered activity its window. The client
// does not choose it: the server is what decides when a photo is still part of
// the same drop.
func stampActivityExpiry(record *core.Record) {
	record.Set("expires", time.Now().Add(photoDropWindow))
}

// sendLive sends to the Live Activity topic, which is the bundle id with
// `.push-type.liveactivity` on the end.
//
// Like send, it reports whether APNs said the token is dead.
func (nt *notifier) sendLive(token string, p *payload.Payload) (dead bool) {
	res, err := nt.client.Push(&apns2.Notification{
		DeviceToken: token,
		Topic:       nt.bundleID + ".push-type.liveactivity",
		Payload:     p,
		PushType:    apns2.PushTypeLiveActivity,
		Priority:    apns2.PriorityHigh,
	})
	if err != nil {
		nt.log().Error("push: live activity send failed", "error", err)
		health.RecordPush(false)
		return false
	}
	health.RecordPush(res.StatusCode == 200)
	if res.StatusCode != 200 {
		nt.log().Warn("push: APNs refused a live activity push",
			"status", res.StatusCode, "reason", res.Reason)
	}
	return tokenIsDead(res)
}
