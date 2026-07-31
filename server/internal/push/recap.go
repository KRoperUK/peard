package push

import (
	"log"
	"sort"
	"strconv"
	"strings"
	"time"

	"peard/internal/moments"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/payload"
)

// weeklyRecapCron fires Sunday evening UTC. No per-user timezone handling and
// no opt-out yet — the simplest version that is still worth sending, with
// both named as the first things to revisit if the day/time turns out wrong
// or somebody asks to turn it off.
const weeklyRecapCron = "0 18 * * 0"

// maxPairsPerRecap and maxRecapPosts bound one run to what a personal-scale
// deployment actually has, the same way the rest of this package does — not
// paginated, because there is no fleet of connections to page through.
const (
	maxPairsPerRecap = 10000
	maxRecapPosts    = 2000
	// How many kinds to name in one push before falling back to "and more".
	maxRecapKinds = 4
)

func registerWeeklyRecap(app core.App) {
	app.Cron().MustAdd("weeklyRecap", weeklyRecapCron, func() {
		sendWeeklyRecaps(app)
	})
}

// sendWeeklyRecaps sends one push per connection that had at least one moment
// logged since Monday, to every member with a registered device — a group
// summary of what the connection did, not a per-member "your week" ledger.
func sendWeeklyRecaps(app core.App) {
	if n == nil {
		return
	}

	pairs, err := app.FindRecordsByFilter("pairs", "", "", maxPairsPerRecap, 0, dbx.Params{})
	if err != nil {
		log.Println("[push] weekly recap: could not list pairs:", err)
		return
	}

	weekStart := startOfWeek(time.Now())
	for _, pair := range pairs {
		sendRecapFor(app, pair, weekStart)
	}
}

func sendRecapFor(app core.App, pair *core.Record, weekStart time.Time) {
	posts, err := app.FindRecordsByFilter("posts",
		"pair = {:pair} && type = 'event' && created >= {:week}",
		"", maxRecapPosts, 0,
		dbx.Params{"pair": pair.Id, "week": weekStart.UTC().Format("2006-01-02 15:04:05.000Z")})
	if err != nil || len(posts) == 0 {
		// Nothing happened, or the query failed — either way, a silent
		// connection gets no recap rather than an empty or broken one.
		return
	}

	body := recapBody(app, pair.Id, posts)
	if body == "" {
		return
	}
	title := "This week"
	if name := pair.GetString("name"); name != "" {
		title = "This week in " + name
	}

	members, err := app.FindRecordsByFilter("pair_members",
		"pair = {:pair}", "", maxFanOut, 0, dbx.Params{"pair": pair.Id})
	if err != nil {
		return
	}

	threadID := "pair-" + pair.Id
	for _, member := range members {
		userID := member.GetString("user")
		devices, err := app.FindRecordsByFilter("devices",
			"user = {:user}", "", 20, 0, dbx.Params{"user": userID})
		if err != nil {
			continue
		}
		for _, d := range devices {
			t := d.GetString("push_token")
			if t == "" {
				continue
			}
			p := payload.NewPayload().
				AlertTitle(title).AlertBody(body).
				Sound("default").
				ThreadID(threadID).
				Custom("pair_id", pair.Id)
			n.send(t, p, apns2.PushTypeAlert, apns2.PriorityLow, "recap:"+pair.Id)
		}
	}
}

// recapBody turns this week's posts into "4 🍺, 2 ☕, 1 💩", most frequent
// first, matching the tallies row style used elsewhere.
func recapBody(app core.App, pairID string, posts []*core.Record) string {
	counts := map[string]int{}
	order := []string{}
	for _, post := range posts {
		kind := post.GetString("event_kind")
		if kind == "" {
			continue
		}
		if _, seen := counts[kind]; !seen {
			order = append(order, kind)
		}
		counts[kind]++
	}
	if len(order) == 0 {
		return ""
	}

	sort.SliceStable(order, func(i, j int) bool { return counts[order[i]] > counts[order[j]] })
	if len(order) > maxRecapKinds {
		order = order[:maxRecapKinds]
	}

	descriptors := moments.ResolveAll(app, pairID, order)
	parts := make([]string, 0, len(order))
	for _, kind := range order {
		d := descriptors[kind]
		parts = append(parts, d.Emoji+" "+strconv.Itoa(counts[kind]))
	}
	return strings.Join(parts, ", ")
}

// startOfWeek pins the week to Monday, matching internal/tallies —
// duplicated rather than imported, the same call the rest of this codebase
// already makes for small time-window helpers (see widget.startOfToday).
func startOfWeek(now time.Time) time.Time {
	day := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	offset := (int(day.Weekday()) + 6) % 7 // Monday = 0
	return day.AddDate(0, 0, -offset)
}
