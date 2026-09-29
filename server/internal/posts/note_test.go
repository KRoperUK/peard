package posts_test

import (
	"testing"
)

// MARK: Replies

// A reply typed into a notification arrives as a post of its own that is only
// words.
func TestAReplyIsAPostOfItsOwn(t *testing.T) {
	w := newWorld(t)

	post := w.create(t, w.aliceTok, `,"type":"note","event_kind":"","note":"enjoy!"`)

	if got := post.GetString("type"); got != "note" {
		t.Errorf("type = %q, want note", got)
	}
	if got := post.GetString("note"); got != "enjoy!" {
		t.Errorf("note = %q, want enjoy!", got)
	}
}

func TestAnEmptyReplyIsRefused(t *testing.T) {
	w := newWorld(t)

	for _, note := range []string{`""`, `"   "`} {
		status, body := w.createRaw(t, w.aliceTok, `,"type":"note","event_kind":"","note":`+note)
		if status != 400 {
			t.Errorf("note %s: status = %d %s, want 400", note, status, body)
		}
	}
}

// Taking the words out of a reply would leave a blank post; deleting it is
// the way to take it back.
func TestAReplyCannotBeEditedEmpty(t *testing.T) {
	w := newWorld(t)
	post := w.create(t, w.aliceTok, `,"type":"note","event_kind":"","note":"enjoy!"`)

	status, body := w.edit(t, w.aliceTok, `{"post":"`+post.Id+`","note":""}`)

	if status != 400 {
		t.Fatalf("status = %d %s, want 400", status, body)
	}
	if got := w.reload(t, post.Id).GetString("note"); got != "enjoy!" {
		t.Errorf("note = %q, want it kept", got)
	}
}
