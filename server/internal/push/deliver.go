package push

import (
	"fmt"
	"runtime/debug"
	"sync"

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

var (
	deliverySlots = make(chan struct{}, maxConcurrentDeliveries)
	deliveries    sync.WaitGroup
)

// deliverInBackground runs one post's or reaction's fan-out off the request.
//
// A panic in it is logged and recovered: the request that caused it has already
// been answered, so there is nobody to return an error to, and it must not take
// the rest of the server down with it.
func deliverInBackground(app core.App, what string, job func()) {
	deliveries.Add(1)
	go func() {
		defer deliveries.Done()
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
