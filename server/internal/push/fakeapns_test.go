package push

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/sideshow/apns2"
)

// fakeAPNs stands in for Apple's push service. It answers each device token
// with the status and reason a test gives it — 200 for anything else — and
// records every token it was sent to, so a test can see what was delivered and
// what the server did about the replies.
type fakeAPNs struct {
	mu      sync.Mutex
	sent    []string
	replies map[string]fakeReply
	hold    chan struct{}
	once    sync.Once
}

type fakeReply struct {
	status int
	reason string
}

// installFakeAPNs points the package's notifier at a fake for the length of the
// test. Anything still being delivered in the background is waited for before
// the app underneath it is torn down.
func installFakeAPNs(t *testing.T, replies map[string]fakeReply) *fakeAPNs {
	t.Helper()
	f := &fakeAPNs{replies: replies, hold: make(chan struct{})}
	f.release()
	srv := httptest.NewServer(http.HandlerFunc(f.serve))
	previous := n
	n = &notifier{client: &apns2.Client{Host: srv.URL, HTTPClient: srv.Client()}, bundleID: "com.peard.test"}
	t.Cleanup(func() {
		f.release()
		waitForDeliveries()
		n = previous
		srv.Close()
	})
	return f
}

// holdReplies makes every request wait until release is called, which is how a
// test tells "the poster waited for Apple" from "it did not".
func (f *fakeAPNs) holdReplies() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hold = make(chan struct{})
	f.once = sync.Once{}
}

func (f *fakeAPNs) release() {
	f.mu.Lock()
	hold := f.hold
	f.mu.Unlock()
	f.once.Do(func() { close(hold) })
}

func (f *fakeAPNs) serve(w http.ResponseWriter, r *http.Request) {
	token := strings.TrimPrefix(r.URL.Path, "/3/device/")
	f.mu.Lock()
	f.sent = append(f.sent, token)
	reply, ok := f.replies[token]
	hold := f.hold
	f.mu.Unlock()
	<-hold
	if !ok {
		return
	}
	w.WriteHeader(reply.status)
	if reply.reason != "" {
		fmt.Fprintf(w, `{"reason":%q}`, reply.reason)
	}
}

func (f *fakeAPNs) sentTo() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.sent...)
}
