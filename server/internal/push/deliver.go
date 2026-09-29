package push

import (
	"fmt"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pocketbase/pocketbase/core"
)

// maxConcurrentDeliveries is how many posts can be fanning out to APNs at once.
//
// Delivery used to run inside the request that created the post, so the poster
// waited for every other member's alert, background push, badge count and Live
// Activity — dozens of serial round trips to Apple for a full group. It now runs
// in the background, and this cap is what stops a burst of posts from opening an
// unbounded number of connections to Apple and queries against SQLite at once.
// A post over the cap waits its turn rather than being dropped.
const maxConcurrentDeliveries = 4

// shutdownGrace is how long shutdown waits for deliveries still in flight.
//
// Delivery happens after the request that caused it has been answered, so a
// redeploy that stops the process mid-fan-out would drop pushes nobody could
// retry: the post is saved, and nothing sends its alert again. Ten seconds is
// longer than a full group's fan-out takes, and short enough that a container
// stop, which escalates to SIGKILL after its own timeout, still gets a clean
// exit.
const shutdownGrace = 10 * time.Second

var (
	deliverySlots = make(chan struct{}, maxConcurrentDeliveries)
	deliveries    sync.WaitGroup
	// inFlight mirrors the WaitGroup's count, which a WaitGroup cannot report,
	// so a shutdown that gives up can say how many it abandoned.
	inFlight atomic.Int64
)

// deliverInBackground runs one post's or reaction's fan-out off the request.
//
// A panic in it is logged and recovered: the request that caused it has already
// been answered, so there is nobody to return an error to, and it must not take
// the rest of the server down with it.
func deliverInBackground(app core.App, what string, job func()) {
	deliveries.Add(1)
	inFlight.Add(1)
	go func() {
		defer deliveries.Done()
		defer inFlight.Add(-1)
		deliverySlots <- struct{}{}
		defer func() { <-deliverySlots }()
		defer func() {
			if r := recover(); r != nil {
				app.Logger().Error("push delivery panicked",
					"what", what, "panic", fmt.Sprint(r), "stack", string(debug.Stack()))
			}
		}()
		job()
	}()
}

// waitForDeliveries blocks until every background delivery started so far has
// finished. Tests use it to make background delivery deterministic.
func waitForDeliveries() {
	deliveries.Wait()
}

// drainDeliveries waits up to grace for background deliveries to finish and
// returns how many were still running when it stopped waiting.
func drainDeliveries(grace time.Duration) int64 {
	done := make(chan struct{})
	go func() {
		deliveries.Wait()
		close(done)
	}()
	select {
	case <-done:
		return 0
	case <-time.After(grace):
		return inFlight.Load()
	}
}

// drainOnTerminate holds shutdown until in-flight deliveries finish, or
// shutdownGrace passes, and says when it had to give up on some.
func drainOnTerminate(app core.App) {
	app.OnTerminate().BindFunc(func(e *core.TerminateEvent) error {
		if left := drainDeliveries(shutdownGrace); left > 0 {
			app.Logger().Warn("push: shutting down with deliveries still in flight",
				"abandoned", left, "waited", shutdownGrace.String())
		}
		return e.Next()
	})
}
