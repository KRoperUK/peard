package push

import (
	"slices"
	"testing"
)

// An answer to a photo tells the person whose photo it was that it was theirs,
// and tells everybody else in the connection whose it was.
func TestAnAnswerToAPhotoSaysWhosePhotoItWas(t *testing.T) {
	w := newPushWorld(t)
	cara := newUser(t, w.app, "cara@example.com")
	newRecord(t, w.app, "pair_members", map[string]any{"pair": w.pair.Id, "user": cara.Id, "role": "member"})
	newRecord(t, w.app, "devices", map[string]any{"user": cara.Id, "platform": "ios", "push_token": "cara-device"})
	photo := newRecord(t, w.app, "posts", map[string]any{
		"pair": w.pair.Id, "author": w.ada.Id, "type": "photo", "media": "p.jpg",
	})
	reply := newRecord(t, w.app, "posts", map[string]any{
		"pair": w.pair.Id, "author": w.bo.Id, "type": "note", "note": "what a view", "reply_to": photo.Id,
	})

	notifyPairMembers(w.app, reply)

	alerts := w.apns.alerts()
	var titles []string
	for _, a := range alerts {
		alert, _ := aps(a)["alert"].(map[string]any)
		title, _ := alert["title"].(string)
		titles = append(titles, title)
		if body, _ := alert["body"].(string); body != "what a view" {
			t.Errorf("body = %q, want the words", body)
		}
		if got, _ := a["reply_to"].(string); got != photo.Id {
			t.Errorf("reply_to = %q, want the photo", got)
		}
		if got, _ := a["post_id"].(string); got != reply.Id {
			t.Errorf("post_id = %q, want the reply", got)
		}
	}
	slices.Sort(titles)
	want := []string{"💬 bo replied to ada's photo", "💬 bo replied to your photo"}
	if !slices.Equal(titles, want) {
		t.Errorf("titles = %q, want %q", titles, want)
	}
}

func TestAPhotoSentBackSaysSo(t *testing.T) {
	w := newPushWorld(t)
	photo := newRecord(t, w.app, "posts", map[string]any{
		"pair": w.pair.Id, "author": w.ada.Id, "type": "photo", "media": "p.jpg",
	})
	reply := newRecord(t, w.app, "posts", map[string]any{
		"pair": w.pair.Id, "author": w.bo.Id, "type": "photo", "media": "q.jpg", "reply_to": photo.Id,
	})

	notifyPairMembers(w.app, reply)

	alert, _ := aps(w.onlyAlert(t))["alert"].(map[string]any)
	if got, _ := alert["title"].(string); got != "📸 bo replied to your photo" {
		t.Errorf("title = %q", got)
	}
}

// A post that answers nothing carries no reply_to, so the app does not go
// looking for a photo that is not there.
func TestAnOrdinaryPostCarriesNoReplyTo(t *testing.T) {
	w := newPushWorld(t)
	post := newRecord(t, w.app, "posts", map[string]any{
		"pair": w.pair.Id, "author": w.ada.Id, "type": "note", "note": "enjoy!",
	})

	notifyPairMembers(w.app, post)

	if got, present := w.onlyAlert(t)["reply_to"]; present {
		t.Errorf("reply_to = %v, want none", got)
	}
}
