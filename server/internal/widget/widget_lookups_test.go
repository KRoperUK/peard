package widget_test

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/dbx"
)

// Member display names are resolved once per request and reused across every
// metric block, so the user lookups cannot grow with the metric count (#440).
// A twelve-person connection tracking three metrics was thirty-six lookups;
// observed at the query log so any future fan-out fails here, not in silence.
func TestFeedResolvesMemberNamesOncePerRequest(t *testing.T) {
	one := newFeedWorld(t)
	one.newMetricPost(t, one.alice, "steps", 4000)

	three := newFeedWorld(t)
	three.newMetricPost(t, three.alice, "steps", 4000)
	three.newMetricPost(t, three.alice, "exercise", 30)
	three.newMetricPost(t, three.alice, "water", 500)

	single := countUsersQueries(t, one)
	triple := countUsersQueries(t, three)

	if single == 0 || triple == 0 {
		t.Fatal("no users queries observed; the counter is not seeing the feed's reads")
	}
	if triple != single {
		t.Errorf("users queries with 3 tracked metrics = %d, with 1 = %d: names must resolve once per request",
			triple, single)
	}
}

// countUsersQueries serves one feed while counting SELECTs against the users
// table through dbx's query log.
func countUsersQueries(t *testing.T, w *feedWorld) int {
	t.Helper()
	count := 0
	log := func(ctx context.Context, d time.Duration, query string, rows *sql.Rows, err error) {
		if strings.Contains(query, "`users`") {
			count++
		}
	}
	for _, builder := range []dbx.Builder{w.app.ConcurrentDB(), w.app.NonconcurrentDB()} {
		db, ok := builder.(*dbx.DB)
		if !ok {
			t.Fatalf("cannot observe queries: %T has no log hook", builder)
		}
		previous := db.QueryLogFunc
		db.QueryLogFunc = func(ctx context.Context, d time.Duration, query string, rows *sql.Rows, err error) {
			log(ctx, d, query, rows, err)
			if previous != nil {
				previous(ctx, d, query, rows, err)
			}
		}
		t.Cleanup(func() { db.QueryLogFunc = previous })
	}
	w.feedMetrics(t)
	return count
}
