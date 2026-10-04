package posts_test

import (
	"testing"

	"github.com/pocketbase/pocketbase/core"
)

// MARK: Answering a photo

func TestAPhotoCanBeAnsweredWithWords(t *testing.T) {
	w := newWorld(t)

	post := w.createAs(t, w.bobTok, w.bob.Id, `,"type":"note","event_kind":"","note":"what a view","reply_to":"`+w.alicePhoto.Id+`"`)

	if got := post.GetString("reply_to"); got != w.alicePhoto.Id {
		t.Errorf("reply_to = %q, want the photo", got)
	}
}

// A photo sent back goes through the same door as any other photo; the
// collection endpoint takes the relation alongside the file.
func TestAPhotoCanBeAnsweredWithAPhoto(t *testing.T) {
	w := newWorld(t)

	post := w.createAs(t, w.bobTok, w.bob.Id, `,"type":"photo","event_kind":"","reply_to":"`+w.alicePhoto.Id+`"`)

	if got := post.GetString("reply_to"); got != w.alicePhoto.Id {
		t.Errorf("reply_to = %q, want the photo", got)
	}
}

// What was asked for is answering photos; a moment without one has nothing to
// show the answer next to.
func TestAMomentWithoutAPhotoCannotBeAnswered(t *testing.T) {
	w := newWorld(t)

	status, body := w.createRaw(t, w.aliceTok, `,"type":"note","event_kind":"","note":"cheers","reply_to":"`+w.bobPost.Id+`"`)

	if status != 400 {
		t.Errorf("status = %d %s, want 400", status, body)
	}
}

// Answering is words or a photo. A moment pointing at a photo would be counted
// in the tallies as if it had been done.
func TestAMomentCannotBeAnAnswer(t *testing.T) {
	w := newWorld(t)

	status, body := w.createRaw(t, w.aliceTok, `,"reply_to":"`+w.alicePhoto.Id+`"`)

	if status != 400 {
		t.Errorf("status = %d %s, want 400", status, body)
	}
}

// Alice is in both connections, so the CreateRule lets her post into either;
// only the reply check stands between a photo in one and an answer in the
// other.
func TestAPhotoInAnotherConnectionCannotBeAnswered(t *testing.T) {
	w := newWorld(t)
	home := w.pair
	w.pair = w.newPair(t)
	w.addMember(t, w.alice)
	elsewhere := w.newPhoto(t, w.alice)
	w.pair = home

	status, body := w.createRaw(t, w.aliceTok, `,"type":"note","event_kind":"","note":"hi","reply_to":"`+elsewhere.Id+`"`)

	if status != 400 {
		t.Errorf("status = %d %s, want 400", status, body)
	}
}

func TestAnAnswerToAPhotoThatIsGoneIsRefused(t *testing.T) {
	w := newWorld(t)

	status, body := w.createRaw(t, w.aliceTok, `,"type":"note","event_kind":"","note":"hi","reply_to":"abcdefghijklmno"`)

	if status != 400 {
		t.Errorf("status = %d %s, want 400", status, body)
	}
}

// Taking a photo back leaves the answers to it standing, pointing at nothing.
func TestDeletingAPhotoLeavesItsAnswers(t *testing.T) {
	w := newWorld(t)
	reply := w.createAs(t, w.bobTok, w.bob.Id, `,"type":"note","event_kind":"","note":"lovely","reply_to":"`+w.alicePhoto.Id+`"`)

	if err := w.app.Delete(w.alicePhoto); err != nil {
		t.Fatalf("delete photo: %v", err)
	}

	if got := w.reload(t, reply.Id).GetString("reply_to"); got != "" {
		t.Errorf("reply_to = %q, want it emptied", got)
	}
}

// createAs is create for somebody other than alice.
func (w *world) createAs(t *testing.T, token, author, extra string) *core.Record {
	t.Helper()
	return w.create(t, token, `,"author":"`+author+`"`+extra)
}
