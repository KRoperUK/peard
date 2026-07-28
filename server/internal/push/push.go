// Package push wires APNs delivery for Pear'd activity: a visible notification
// plus a silent background nudge (so the app can refresh the App Group
// container and reload the widget timeline) when a partner posts, and a
// visible notification for reactions.
//
// The whole package is a no-op unless these env vars are set:
//   PEARD_APNS_KEY_PATH   path to the .p8 APNs auth key
//   PEARD_APNS_KEY_ID     10-char key id
//   PEARD_APNS_TEAM_ID    Apple Developer team id
//   PEARD_APNS_BUNDLE_ID  default "com.peard.app"
//   PEARD_APNS_PRODUCTION "true" to use the production APNs host
package push

import (
	"log"
	"os"
	"strings"

	"peard/internal/moments"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/payload"
	"github.com/sideshow/apns2/token"
)

type notifier struct {
	client   *apns2.Client
	bundleID string
}

var n *notifier

// Register configures the APNs client and binds the record hooks.
func Register(app core.App) {
	n = newNotifier()
	if n == nil {
		log.Println("[push] APNs not configured (PEARD_APNS_* missing); push disabled")
	} else {
		log.Println("[push] APNs configured for bundle", n.bundleID)
	}

	app.OnRecordAfterCreateSuccess("posts").BindFunc(func(e *core.RecordEvent) error {
		notifyPairMembers(app, e.Record)
		return e.Next()
	})
	app.OnRecordAfterCreateSuccess("reactions").BindFunc(func(e *core.RecordEvent) error {
		notifyPostAuthor(app, e.Record)
		return e.Next()
	})
}

func newNotifier() *notifier {
	keyPath := os.Getenv("PEARD_APNS_KEY_PATH")
	keyID := os.Getenv("PEARD_APNS_KEY_ID")
	teamID := os.Getenv("PEARD_APNS_TEAM_ID")
	bundleID := os.Getenv("PEARD_APNS_BUNDLE_ID")
	if bundleID == "" {
		bundleID = "com.peard.app"
	}
	if keyPath == "" || keyID == "" || teamID == "" {
		return nil
	}
	keyBytes, err := os.ReadFile(keyPath)
	if err != nil {
		log.Println("[push] cannot read APNs key:", err)
		return nil
	}
	authKey, err := token.AuthKeyFromBytes(keyBytes)
	if err != nil {
		log.Println("[push] cannot parse APNs key:", err)
		return nil
	}
	t := &token.Token{AuthKey: authKey, KeyID: keyID, TeamID: teamID}
	client := apns2.NewTokenClient(t)
	if strings.EqualFold(os.Getenv("PEARD_APNS_PRODUCTION"), "true") {
		client = client.Production()
	} else {
		client = client.Development()
	}
	return &notifier{client: client, bundleID: bundleID}
}

// notifyPairMembers alerts every other member of the pair about a new post.
func notifyPairMembers(app core.App, post *core.Record) {
	if n == nil {
		return
	}
	pairID := post.GetString("pair")
	authorID := post.GetString("author")
	author, _ := app.FindRecordById("users", authorID)
	name := displayName(author)

	members, err := app.FindRecordsByFilter("pair_members",
		"pair = {:pair} && user != {:author}", "", 10, 0,
		dbx.Params{"pair": pairID, "author": authorID})
	if err != nil {
		return
	}
	title, body := copyFor(app, name, post)
	for _, m := range members {
		devices, err := app.FindRecordsByFilter("devices",
			"user = {:user}", "", 20, 0, dbx.Params{"user": m.GetString("user")})
		if err != nil {
			continue
		}
		for _, d := range devices {
			t := d.GetString("push_token")
			if t == "" {
				continue
			}
			visible := payload.NewPayload().
				AlertTitle(title).AlertBody(body).
				Sound("default").MutableContent().
				Custom("post_id", post.Id)
			n.send(t, visible, apns2.PushTypeAlert, apns2.PriorityHigh)

			silent := payload.NewPayload().
				ContentAvailable().
				Custom("post_id", post.Id)
			n.send(t, silent, apns2.PushTypeBackground, apns2.PriorityLow)
		}
	}
}

// notifyPostAuthor tells the author their partner reacted.
func notifyPostAuthor(app core.App, reaction *core.Record) {
	if n == nil {
		return
	}
	post, err := app.FindRecordById("posts", reaction.GetString("post"))
	if err != nil {
		return
	}
	authorID := post.GetString("author")
	if authorID == reaction.GetString("user") {
		return
	}
	reacter, _ := app.FindRecordById("users", reaction.GetString("user"))
	name := displayName(reacter)

	devices, err := app.FindRecordsByFilter("devices",
		"user = {:user}", "", 20, 0, dbx.Params{"user": authorID})
	if err != nil {
		return
	}
	for _, d := range devices {
		t := d.GetString("push_token")
		if t == "" {
			continue
		}
		p := payload.NewPayload().
			AlertTitle(reactionEmoji(reaction.GetString("kind")) + " " + name + " reacted").
			Sound("default").
			Custom("post_id", post.Id)
		n.send(t, p, apns2.PushTypeAlert, apns2.PriorityHigh)
	}
}

func (nt *notifier) send(deviceToken string, p *payload.Payload, pushType apns2.EPushType, priority int) {
	res, err := nt.client.Push(&apns2.Notification{
		DeviceToken: deviceToken,
		Topic:       nt.bundleID,
		Payload:     p,
		PushType:    pushType,
		Priority:    priority,
	})
	if err != nil {
		log.Println("[push] send error:", err)
		return
	}
	if res.StatusCode != 200 {
		log.Printf("[push] APNs status %d: %s\n", res.StatusCode, res.Reason)
	}
}

// copyFor writes the alert for a new post. Built-in kinds keep their hand-written
// copy; anything else is described from the connection's moment catalogue, so a
// custom moment arrives with its own emoji and label rather than "something".
func copyFor(app core.App, name string, post *core.Record) (title, body string) {
	pairID := post.GetString("pair")
	suffix := groupSuffix(app, pairID)

	if post.GetString("type") == "event" {
		kind := post.GetString("event_kind")
		switch kind {
		case "beer":
			return "🍺 " + name + " cracked a cold one" + suffix, "Cheers them back?"
		case "loo":
			return "💩 " + name + " has gone to the loo" + suffix, "Nature called."
		}
		d := moments.Resolve(app, pairID, kind)
		if d.Label != "" {
			title = d.Emoji + " " + name + ": " + d.Label + suffix
		} else {
			title = moments.FallbackEmoji + " " + name + " logged something" + suffix
		}
		return title, post.GetString("note")
	}

	body = post.GetString("note")
	if body == "" {
		body = "Tap to see the moment"
	}
	return "🍐 Fresh pear from " + name + suffix, body
}

// groupSuffix names the connection when it holds more than two people, so a
// member of several groups can tell where a moment came from.
func groupSuffix(app core.App, pairID string) string {
	if pairID == "" {
		return ""
	}
	members, err := app.FindRecordsByFilter("pair_members",
		"pair = {:pair}", "", 13, 0, dbx.Params{"pair": pairID})
	if err != nil || len(members) <= 2 {
		return ""
	}
	pair, err := app.FindRecordById("pairs", pairID)
	if err != nil {
		return ""
	}
	if name := pair.GetString("name"); name != "" {
		return " in " + name
	}
	return ""
}

func reactionEmoji(kind string) string {
	switch kind {
	case "cheers":
		return "🍻"
	case "plus_one":
		return "👏"
	default:
		return "🍐"
	}
}

func displayName(user *core.Record) string {
	if user == nil {
		return "Your partner"
	}
	if n := user.GetString("display_name"); n != "" {
		return n
	}
	if email := user.GetString("email"); email != "" {
		if i := strings.Index(email, "@"); i > 0 {
			return email[:i]
		}
	}
	return "Your partner"
}
