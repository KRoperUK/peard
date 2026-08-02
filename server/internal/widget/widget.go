// Package widget implements the feed consumed by the Pear'd WidgetKit
// extension, plus issuing of the revocable, scope-limited widget tokens.
//
// Routes:
//
//	GET  /api/peard/widget/feed?token=...  (widget-token auth, no PB session)
//	POST /api/peard/widget/token           (requires PB auth; issues a token)
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
	// For UnreadCount — one definition of "unread" shared with the connections
	// route and the push badge. `pairs` imports nothing internal, so no cycle.
	"peard/internal/pairs"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// Bounds mirroring internal/pairs, used when the widget routes walk a caller's
// memberships or a connection's members without going through that package.
const (
	maxConnections = 20
	maxMembers     = 12
	// A widget has room for a handful of buttons; this only guards the query.
	widgetMomentCatalogueLimit = 50
)

// Register binds the widget routes.
func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.GET("/api/peard/widget/feed", feedHandler(app))
		se.Router.GET("/api/peard/widget/connections", connectionsHandler(app))
		se.Router.POST("/api/peard/widget/moment", momentHandler(app))
		se.Router.POST("/api/peard/widget/token", issueTokenHandler(app)).Bind(apis.RequireAuth())
		return se.Next()
	})
}

// resolveToken authenticates a widget-token request and returns the owning user
// id. Every widget route goes through this rather than apis.RequireAuth: the
// extension has no PocketBase session, only the revocable token in the App Group
// container.
func resolveToken(app core.App, e *core.RequestEvent, token string) (string, error) {
	if token == "" {
		return "", e.UnauthorizedError("missing token", nil)
	}
	wt, err := app.FindFirstRecordByFilter("widget_tokens",
		"token = {:token} && revoked = false", dbx.Params{"token": token})
	if err != nil || wt == nil {
		return "", e.UnauthorizedError("invalid token", nil)
	}
	if exp := wt.GetDateTime("expires"); !exp.IsZero() && exp.Time().Before(time.Now()) {
		return "", e.UnauthorizedError("token expired", nil)
	}
	return wt.GetString("user"), nil
}

// connectionsHandler lists the caller's connections so a configurable widget can
// offer a choice of which one to show.
//
// Deliberately thinner than /api/peard/connections: a title, whether it is a
// group, and the id. The widget needs enough to draw a picker and nothing more,
// and this endpoint is reachable with the widget token rather than a session.
//
// `?moments=1` adds each connection's catalogue. The Shortcuts moment picker
// needs every connection's moments at once — a custom kind is only valid in the
// connection that published it, so the picker names both — and was fetching them
// one connection at a time through the feed endpoint, which is a full feed
// (tallies, latest post, unread count) per connection to read one list. Opt-in
// rather than always-on because the widget's own picker does not want them and
// this walks moment_kinds once per connection.
func connectionsHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		userID, err := resolveToken(app, e, e.Request.URL.Query().Get("token"))
		if err != nil {
			return err
		}
		withMoments := e.Request.URL.Query().Get("moments") == "1"

		memberships, ferr := app.FindRecordsByFilter("pair_members",
			"user = {:user}", "created", maxConnections, 0, dbx.Params{"user": userID})
		if ferr != nil {
			return e.InternalServerError("could not read your connections", ferr)
		}

		out := make([]map[string]any, 0, len(memberships))
		for _, membership := range memberships {
			pairID := membership.GetString("pair")
			members, merr := app.FindRecordsByFilter("pair_members",
				"pair = {:pair}", "created", maxMembers, 0, dbx.Params{"pair": pairID})
			if merr != nil {
				continue
			}
			connection := map[string]any{
				"id":           pairID,
				"title":        connectionTitle(app, pairID, members, userID),
				"member_count": len(members),
				"is_group":     len(members) > 2,
			}
			if withMoments {
				connection["moments"] = availableMoments(app, pairID)
			}
			out = append(out, connection)
		}
		return e.JSON(http.StatusOK, map[string]any{"connections": out})
	}
}

// momentHandler logs a moment from the widget's own buttons.
//
// This is what makes the widget interactive without sharing the Keychain with the
// extension. The alternative was a keychain access group so the widget could read
// the PocketBase session token — a much wider grant for a much smaller job. The
// widget token is already revocable and already in the App Group container, and
// this route only ever creates an `event` post.
//
// `client_id` is honoured so a tap whose response is lost cannot double-log: the
// partial unique index on posts rejects the repeat.
func momentHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			Token    string `json:"token" form:"token"`
			Pair     string `json:"pair" form:"pair"`
			Kind     string `json:"kind" form:"kind"`
			ClientID string `json:"client_id" form:"client_id"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}
		userID, err := resolveToken(app, e, strings.TrimSpace(body.Token))
		if err != nil {
			return err
		}

		kind := strings.TrimSpace(body.Kind)
		if kind == "" {
			return e.BadRequestError("kind is required", nil)
		}

		pairID := strings.TrimSpace(body.Pair)
		if pairID == "" {
			// No connection named: use whichever the feed would have shown, so a
			// widget with no configuration still works.
			pairID = liveliestPair(app, userID)
		}
		if pairID == "" {
			return e.NotFoundError("you are not pear'd with anyone", nil)
		}
		member, merr := app.FindFirstRecordByFilter("pair_members",
			"pair = {:pair} && user = {:user}",
			dbx.Params{"pair": pairID, "user": userID})
		if merr != nil || member == nil {
			return e.ForbiddenError("you are not a member of that connection", nil)
		}

		// The widget may only log a moment the connection already knows about.
		// Without this it would be a route for writing arbitrary 40-character
		// strings into event_kind, which every other client would then render as a
		// pear.
		if !isKnownKind(app, pairID, kind) {
			return e.BadRequestError("that moment isn't available in this connection", nil)
		}

		col, cerr := app.FindCollectionByNameOrId("posts")
		if cerr != nil {
			return e.InternalServerError("posts collection missing", cerr)
		}
		post := core.NewRecord(col)
		post.Set("pair", pairID)
		post.Set("author", userID)
		post.Set("type", "event")
		post.Set("event_kind", kind)
		if id := strings.TrimSpace(body.ClientID); id != "" {
			post.Set("client_id", id)
		}
		if err := app.Save(post); err != nil {
			return e.BadRequestError("failed to log that moment", err)
		}

		descriptor := moments.Resolve(app, pairID, kind)
		return e.JSON(http.StatusOK, map[string]any{
			"id":    post.Id,
			"pair":  pairID,
			"kind":  kind,
			"emoji": descriptor.Emoji,
			"label": descriptor.Label,
		})
	}
}

// isKnownKind reports whether a slug is a built-in moment or one this connection
// has published.
func isKnownKind(app core.App, pairID, slug string) bool {
	if _, ok := moments.Builtin(slug); ok {
		return true
	}
	rec, err := app.FindFirstRecordByFilter("moment_kinds",
		"pair = {:pair} && slug = {:slug}",
		dbx.Params{"pair": pairID, "slug": slug})
	return err == nil && rec != nil
}

// connectionTitle mirrors the client's Connection.title(): the name somebody set,
// else who else is in it.
func connectionTitle(app core.App, pairID string, members []*core.Record, userID string) string {
	if pair, err := app.FindRecordById("pairs", pairID); err == nil {
		if name := pair.GetString("name"); name != "" {
			return name
		}
	}
	names := make([]string, 0, len(members))
	for _, member := range members {
		otherID := member.GetString("user")
		if otherID == userID {
			continue
		}
		user, _ := app.FindRecordById("users", otherID)
		names = append(names, displayName(user))
	}
	switch len(names) {
	case 0:
		return "Just you"
	case 1:
		return names[0]
	case 2:
		return names[0] + " & " + names[1]
	default:
		return fmt.Sprintf("%s +%d", names[0], len(names)-1)
	}
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
//
// `pair` pins the feed to one connection, which is what a configurable widget
// sends. Without it the server picks the liveliest — the original behaviour, and
// still the right default for an unconfigured widget.
func feedHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		query := e.Request.URL.Query()
		userID, err := resolveToken(app, e, query.Get("token"))
		if err != nil {
			return err
		}

		memberships, ferr := app.FindRecordsByFilter("pair_members",
			"user = {:user}", "-created", 50, 0, dbx.Params{"user": userID})
		if ferr != nil || len(memberships) == 0 {
			return e.JSON(http.StatusOK, map[string]any{"state": "unpaired"})
		}

		requested := strings.TrimSpace(query.Get("pair"))
		var chosenPair string
		var latest *core.Record

		if requested != "" && isMemberOf(memberships, requested) {
			chosenPair = requested
			posts, _ := app.FindRecordsByFilter("posts",
				"pair = {:pair} && author != {:user}", "-created", 1, 0,
				dbx.Params{"pair": chosenPair, "user": userID})
			if len(posts) > 0 {
				latest = posts[0]
			}
		} else {
			// The connection somebody else posted in most recently, falling back to
			// the first membership when nobody else has posted anywhere yet.
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
		}

		others, oerr := app.FindRecordsByFilter("pair_members",
			"pair = {:pair} && user != {:user}", "", 50, 0,
			dbx.Params{"pair": chosenPair, "user": userID})
		if oerr != nil || len(others) == 0 {
			// A connection the user is alone in has nothing to show.
			return e.JSON(http.StatusOK, map[string]any{"state": "unpaired"})
		}

		res := map[string]any{
			"state":      "ok",
			"connection": connectionInfo(app, chosenPair, len(others)+1),
			"counts":     todayCounts(app, chosenPair, userID),
			"tallies":    todayTallies(app, chosenPair, userID),
			// The same count the rail and the badge use, for the connection this
			// widget is showing. Without it the widget was the one surface that
			// could not tell you whether the moment on it was one you had already
			// seen — which is most of what a home-screen widget is *for*.
			"unread": unreadForWidget(app, chosenPair, userID),
			// What the widget's own buttons may log, resolved here so the extension
			// does not need the connection's catalogue.
			"moments": availableMoments(app, chosenPair),
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
			// posts.media is a protected file field, so the bytes need a file
			// token. The widget cannot mint one — that endpoint wants a real
			// session and the extension has only its widget token — so the
			// token is minted here, for the user this feed belongs to, and
			// travels with the URL.
			//
			// A failure drops the media rather than failing the feed: a widget
			// showing the moment without its photo is worth much more than one
			// showing nothing at all.
			if owner, err := app.FindRecordById("users", userID); err == nil {
				if fileToken, terr := owner.NewFileToken(); terr == nil {
					mediaURL += "&token=" + fileToken
				} else {
					mediaURL = ""
				}
			} else {
				mediaURL = ""
			}
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

// isMemberOf reports whether one of the caller's memberships is for this pair,
// so a configured pair id cannot be used to read a connection the caller left.
func isMemberOf(memberships []*core.Record, pairID string) bool {
	for _, membership := range memberships {
		if membership.GetString("pair") == pairID {
			return true
		}
	}
	return false
}

// liveliestPair is the connection somebody else posted in most recently, used
// when the widget has not been configured with one.
func liveliestPair(app core.App, userID string) string {
	memberships, err := app.FindRecordsByFilter("pair_members",
		"user = {:user}", "-created", maxConnections, 0, dbx.Params{"user": userID})
	if err != nil || len(memberships) == 0 {
		return ""
	}
	best := ""
	var bestAt time.Time
	for _, mem := range memberships {
		pairID := mem.GetString("pair")
		posts, _ := app.FindRecordsByFilter("posts",
			"pair = {:pair} && author != {:user}", "-created", 1, 0,
			dbx.Params{"pair": pairID, "user": userID})
		if len(posts) == 0 {
			continue
		}
		at := posts[0].GetDateTime("created").Time()
		if best == "" || at.After(bestAt) {
			best = pairID
			bestAt = at
		}
	}
	if best == "" {
		return memberships[0].GetString("pair")
	}
	return best
}

// availableMoments is what the widget's buttons may log: the built-ins plus
// whatever the connection has published, in the same precedence order the client
// uses (a published kind replaces a built-in of the same slug).
func availableMoments(app core.App, pairID string) []map[string]any {
	order := []string{"beer", "loo", "coffee"}
	byKind := map[string]moments.Descriptor{}
	for _, slug := range order {
		if d, ok := moments.Builtin(slug); ok {
			byKind[slug] = d
		}
	}

	records, err := app.FindRecordsByFilter("moment_kinds",
		"pair = {:pair}", "created", widgetMomentCatalogueLimit, 0, dbx.Params{"pair": pairID})
	if err == nil {
		for _, rec := range records {
			slug := rec.GetString("slug")
			if slug == "" {
				continue
			}
			if _, seen := byKind[slug]; !seen {
				order = append(order, slug)
			}
			byKind[slug] = moments.Descriptor{
				Slug:  slug,
				Emoji: firstNonEmptyString(rec.GetString("emoji"), moments.FallbackEmoji),
				Label: firstNonEmptyString(rec.GetString("label"), slug),
			}
		}
	}

	out := make([]map[string]any, 0, len(order))
	for _, slug := range order {
		d := byKind[slug]
		out = append(out, map[string]any{
			"kind":  slug,
			"emoji": d.Emoji,
			"label": d.Label,
		})
	}
	return out
}

func firstNonEmptyString(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
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
// unreadForWidget is the connection's unread count for this user, via the same
// helpers the connections route and the push badge use.
//
// Routed through `pairs` rather than reimplemented on the membership here for
// the reason stated at `pairs.UnreadSince`: three definitions of "unread" that
// can drift apart is worse than an import. Zero when the membership cannot be
// read, which matches the rest of this file — the widget degrades to showing
// less, never to showing something wrong.
func unreadForWidget(app core.App, pairID, userID string) int {
	membership, err := app.FindFirstRecordByFilter("pair_members",
		"pair = {:pair} && user = {:user}",
		dbx.Params{"pair": pairID, "user": userID})
	if err != nil || membership == nil {
		return 0
	}
	return pairs.UnreadCount(app, membership, userID)
}

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
