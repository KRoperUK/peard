// Package health keeps a few facts about the server's background work, so a
// superuser can see at a glance whether it is doing its job:
//
//	GET /api/peard/admin/status (superusers only)
//
// Push delivery, the weekly recap, the invite sweep and the backup check all
// run off the request path, where a failure only ever reached the logs. This is
// the one place that answers "is APNs set up, when did the recap last run, how
// old is the newest backup" without reading them.
//
// Everything is in memory and counts from the last boot. That is enough to spot
// a job that has stopped, which is the question, and it keeps this from
// becoming another table to migrate.
package health

import (
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// Job is the outcome of a background job's latest run.
type Job struct {
	LastRun time.Time `json:"last_run"`
	OK      bool      `json:"ok"`
	Detail  string    `json:"detail,omitempty"`
}

var (
	mu      sync.Mutex
	jobs    = map[string]Job{}
	facts   = map[string]any{}
	started = time.Now().UTC()

	pushesSent   atomic.Int64
	pushesFailed atomic.Int64
)

// RecordJob notes a run of a background job. A non-nil err marks it failed and
// becomes its detail; otherwise detail is kept as given.
func RecordJob(name string, err error, detail string) {
	job := Job{LastRun: time.Now().UTC(), OK: err == nil, Detail: detail}
	if err != nil {
		job.Detail = err.Error()
	}
	mu.Lock()
	jobs[name] = job
	mu.Unlock()
}

// RecordPush counts one attempt to deliver a notification to APNs.
func RecordPush(delivered bool) {
	if delivered {
		pushesSent.Add(1)
	} else {
		pushesFailed.Add(1)
	}
}

// Set records a fact worth showing, such as whether APNs is configured.
func Set(key string, value any) {
	mu.Lock()
	facts[key] = value
	mu.Unlock()
}

// Snapshot is the status as served.
func Snapshot() map[string]any {
	mu.Lock()
	defer mu.Unlock()
	jobsCopy := make(map[string]Job, len(jobs))
	for k, v := range jobs {
		jobsCopy[k] = v
	}
	factsCopy := make(map[string]any, len(facts))
	for k, v := range facts {
		factsCopy[k] = v
	}
	return map[string]any{
		"since": started,
		"push": map[string]any{
			"sent":   pushesSent.Load(),
			"failed": pushesFailed.Load(),
		},
		"jobs":  jobsCopy,
		"facts": factsCopy,
	}
}

// Register serves the status to superusers.
func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.GET("/api/peard/admin/status", func(e *core.RequestEvent) error {
			return e.JSON(http.StatusOK, Snapshot())
		}).Bind(apis.RequireSuperuserAuth())
		return se.Next()
	})
}

// reset clears everything, for tests.
func reset() {
	mu.Lock()
	jobs = map[string]Job{}
	facts = map[string]any{}
	mu.Unlock()
	pushesSent.Store(0)
	pushesFailed.Store(0)
}
