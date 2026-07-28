// Package widget implements the feed consumed by the Pear'd WidgetKit
// extension, plus issuing of the revocable, scope-limited widget tokens.
//
// Routes:
//   GET  /api/peard/widget/feed?token=...  (widget-token auth, no PB session)
//   POST /api/peard/widget/token           (requires PB auth; issues a token)
//
// The widget token is deliberately NOT the user's PocketBase auth token:
// it lives in the App Group container readable by the extension, and can be
// revoked independently.
//
// A user may belong to several connections, and the widget has room for one, so
// the feed picks the connection somebody else posted in most recently. That
// keeps a single-connection user's behaviour identical to before while making
// the widget follow whichever group is currently alive.
package widget

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"peard/internal/moments"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// Register binds the widget routes.
func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.GET("/api/peard/widget/feed", feedHandler(app))
		se.Router.POST("/api/peard/widget/token", issueTokenHandler(app)).Bind(apis.RequireAuth())
		return se.Next()
	})
}

func issueTokenHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			return e.InternalServerError("rng failure", err)
		}
		token := hex.EncodeToString(b)

		col, err := app.FindCollectionByNameOrId("widget_tokens")
		if err != nil {
			return e.InternalServerError("widget_tokens collection missing", err)
		}
		rec := core.NewRecord(col)
		rec.Set("user", e.Auth.Id)
		rec.Set("token", token)
		rec.Set("label", "ios-widget")
		if err := app.Save(rec); err != nil {
			return e.InternalServerError("failed to store token", err)
		}
		return e.JSON(http.StatusOK, map[string]any{"id": rec.Id, "token": token})
	}
}

// feedHandler returns everything the home-screen widget needs in one call: the
// latest moment somebody else shared, who shared it, which connection it came
// from, and today's tallies for that connection.
func feedHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		token := e.Request.URL.Query().Get("token")
		if token == "" {
			return e.UnauthorizedError("missing token", nil)
		}
		wt, err := app.FindFirstRecordByFilter("widget_tokens",
			"token = {:token} && revoked = false", dbx.Params{"token": token})
		if err != nil || wt == nil {
			return e.UnauthorizedError("invalid token", nil)
		}
		if exp := wt.GetDateTime("expires"); !exp.IsZero() && exp.Time().Before(time.Now()) {
			return e.UnauthorizedError("token expired", nil)
		}
		userID := wt.GetString("user")

		memberships, err := app.FindRecordsByFilter("pair_members",
			"user = {:user}", "-created", 50, 0, dbx.Params{"user": userID})
		if err != nil || len(memberships) == 0 {
			return e.JSON(http.StatusOK, map[string]any{"state": "unpaired"})
		}

		// The connection somebody else posted in most recently, falling back to
		// the first membership when nobody else has posted anywhere yet.
		var chosenPair string
		var latest *core.Record
		for _, mem := range memberships {
			pairID := mem.GetString("pair")
			posts, _ := app.FindRecordsByFilter("posts",
				"pair = {:pair} && author != {:user}",
				"-created", 1, 0,
				dbx.Params{"pair": pairID, "user": userID})
			if len(posts) == 0 {
				continue
			}
			if latest == nil || posts[0].GetDateTime("created").Time().After(latest.GetDateTime("created").Time()) {
				latest = posts[0]
				chosenPair = pairID
			}
		}
		if chosenPair == "" {
			chosenPair = memberships[0].GetString("pair")
		}

		others, err := app.FindRecordsByFilter("pair_members",
			"pair = {:pair} && user != {:user}", "", 50, 0,
			dbx.Params{"pair": chosenPair, "user": userID})
		if err != nil || len(others) == 0 {
			// A connection the user is alone in has nothing to show.
			return e.JSON(http.StatusOK, map[string]any{"state": "unpaired"})
		}

		res := map[string]any{
			"state":      "ok",
			"connection": connectionInfo(app, chosenPair, len(others)+1),
			"counts":     todayCounts(app, chosenPair, userID),
			"tallies":    todayTallies(app, chosenPair, userID),
		}

		// Who the moment is "from": in a 1:1 that is the other member, in a
		// group it is whoever posted.
		var attributed *core.Record
		if latest != nil && chosenPair == latest.GetString("pair") {
			attributed, _ = app.FindRecordById("users", latest.GetString("author"))
		} else {
			latest = nil
			attributed, _ = app.FindRecordById("users", others[0].GetString("user"))
		}
		partnerName := displayName(attributed)
		res["partner"] = map[string]any{"name": partnerName}

		if latest == nil {
			res["state"] = "empty"
			return e.JSON(http.StatusOK, res)
		}

		mediaURL := ""
		if media := latest.GetString("media"); media != "" {
			mediaURL = fmt.Sprintf("%s/api/files/%s/%s/%s?thumb=512x512",
				baseURL(app, e), latest.Collection().Id, latest.Id, url.PathEscape(media))
		}
		kind := latest.GetString("event_kind")
		descriptor := moments.Resolve(app, chosenPair, kind)
		res["post"] = map[string]any{
			"id":         latest.Id,
			"type":       latest.GetString("type"),
			"event_kind": kind,
			"emoji":      descriptor.Emoji,
			"label":      descriptor.Label,
			"note":       latest.GetString("note"),
			"created":    latest.GetString("created"),
			"media_url":  mediaURL,
			"author":     partnerName,
		}
		return e.JSON(http.StatusOK, res)
	}
}

// connectionInfo describes the connection the feed is showing, so the widget can
// caption a group rather than implying a single partner.
func connectionInfo(app core.App, pairID string, memberCount int) map[string]any {
	name := ""
	if pair, err := app.FindRecordById("pairs", pairID); err == nil {
		name = pair.GetString("name")
	}
	return map[string]any{
		"id":           pairID,
		"name":         name,
		"member_count": memberCount,
		"is_group":     memberCount > 2,
	}
}

// todayCounts keeps the original beer/loo shape so a widget build that predates
// generalised tallies keeps working.
func todayCounts(app core.App, pairID, userID string) map[string]int {
	return map[string]int{
		"beer": len(todayPosts(app, pairID, userID, "beer")),
		"loo":  len(todayPosts(app, pairID, userID, "loo")),
	}
}

// todayTallies counts every kind anybody else logged in this connection today,
// most frequent first.
func todayTallies(app core.App, pairID, userID string) []map[string]any {
	posts, err := app.FindRecordsByFilter("posts",
		"pair = {:pair} && author != {:user} && type = 'event' && created >= {:today}",
		"", 500, 0,
		dbx.Params{"pair": pairID, "user": userID, "today": startOfToday()})
	if err != nil {
		return []map[string]any{}
	}

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

	descriptors := moments.ResolveAll(app, pairID, order)
	sort.SliceStable(order, func(i, j int) bool { return counts[order[i]] > counts[order[j]] })

	out := make([]map[string]any, 0, len(order))
	for _, kind := range order {
		d := descriptors[kind]
		out = append(out, map[string]any{
			"kind":  kind,
			"emoji": d.Emoji,
			"label": d.Label,
			"count": counts[kind],
		})
	}
	return out
}

func todayPosts(app core.App, pairID, userID, kind string) []*core.Record {
	recs, _ := app.FindRecordsByFilter("posts",
		"pair = {:pair} && author != {:user} && type = 'event' && event_kind = {:kind} && created >= {:today}",
		"", 500, 0,
		dbx.Params{
			"pair":  pairID,
			"user":  userID,
			"kind":  kind,
			"today": startOfToday(),
		})
	return recs
}

// startOfToday is local midnight, expressed the way PocketBase stores
// timestamps. Formatting the local date directly (the original behaviour) built
// a naive string that was then compared against UTC values, so "today" was off
// by the UTC offset — an hour of moments landed in the wrong day in BST, and a
// whole evening of them further east.
func startOfToday() string {
	now := time.Now()
	midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	return midnight.UTC().Format("2006-01-02 15:04:05.000Z")
}

func displayName(user *core.Record) string {
	if user == nil {
		return "Partner"
	}
	if n := user.GetString("display_name"); n != "" {
		return n
	}
	if email := user.GetString("email"); email != "" {
		if i := strings.Index(email, "@"); i > 0 {
			return email[:i]
		}
	}
	return "Partner"
}

func baseURL(app core.App, e *core.RequestEvent) string {
	if u := strings.TrimRight(app.Settings().Meta.AppURL, "/"); u != "" {
		return u
	}
	scheme := e.Request.URL.Scheme
	if scheme == "" {
		scheme = "http"
	}
	return scheme + "://" + e.Request.Host
}
