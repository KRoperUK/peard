package push

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/payload"
)

// captureHandler keeps every record logged through it, so a test can check
// what reached the app's structured log rather than stderr.
type captureHandler struct {
	mu      sync.Mutex
	records []slog.Record
}

func (h *captureHandler) Enabled(context.Context, slog.Level) bool { return true }
func (h *captureHandler) Handle(_ context.Context, r slog.Record) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.records = append(h.records, r)
	return nil
}
func (h *captureHandler) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h *captureHandler) WithGroup(string) slog.Handler      { return h }

func attrsOf(r slog.Record) map[string]any {
	attrs := map[string]any{}
	r.Attrs(func(a slog.Attr) bool {
		attrs[a.Key] = a.Value.Any()
		return true
	})
	return attrs
}

// A refusal from APNs lands in the app's log with its status and reason as
// fields, where the dashboard can find and filter it.
func TestAnAPNsRefusalIsLoggedWithItsStatusAndReason(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"reason":"BadTopic"}`))
	}))
	t.Cleanup(srv.Close)
	logs := &captureHandler{}
	nt := &notifier{
		client:   &apns2.Client{Host: srv.URL, HTTPClient: srv.Client()},
		bundleID: "com.peard.test",
		logger:   slog.New(logs),
	}

	nt.send("some-device", payload.NewPayload().AlertTitle("hi"), apns2.PushTypeAlert, apns2.PriorityHigh, "pair1:beer")
	nt.sendLive("some-activity", payload.NewPayload())

	if len(logs.records) != 2 {
		t.Fatalf("logged %d records, want one per refusal", len(logs.records))
	}
	for _, r := range logs.records {
		attrs := attrsOf(r)
		if attrs["status"] != int64(400) || attrs["reason"] != "BadTopic" {
			t.Errorf("%q logged with %v, want status 400 and reason BadTopic", r.Message, attrs)
		}
	}
}
