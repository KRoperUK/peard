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
package widget

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

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

// feedHandler returns everything the home-screen widget needs in one call:
// the partner's latest post (with a ready-to-fetch thumbnail URL) and their
// event tallies for today.
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

		// MVP: one pair per user, so the first membership is the pair.
		mem, err := app.FindFirstRecordByFilter("pair_members",
			"user = {:user}", dbx.Params{"user": userID})
		if err != nil || mem == nil {
			return e.JSON(http.StatusOK, map[string]any{"state": "unpaired"})
		}
		pairID := mem.GetString("pair")

		partnerMem, err := app.FindFirstRecordByFilter("pair_members",
			"pair = {:pair} && user != {:user}", dbx.Params{"pair": pairID, "user": userID})
		if err != nil || partnerMem == nil {
			return e.JSON(http.StatusOK, map[string]any{"state": "unpaired"})
		}
		partner, _ := app.FindRecordById("users", partnerMem.GetString("user"))
		partnerName := displayName(partner)

		posts, _ := app.FindRecordsByFilter("posts",
			"pair = {:pair} && author = {:author}",
			"-created", 1, 0,
			dbx.Params{"pair": pairID, "author": partnerMem.GetString("user")})

		today := time.Now().Format("2006-01-02 00:00:00")
		countToday := func(kind string) int {
			recs, _ := app.FindRecordsByFilter("posts",
				"pair = {:pair} && author = {:author} && type = 'event' && event_kind = {:kind} && created >= {:today}",
				"", 500, 0,
				dbx.Params{
					"pair":   pairID,
					"author": partnerMem.GetString("user"),
					"kind":   kind,
					"today":  today,
				})
			return len(recs)
		}

		res := map[string]any{
			"state":   "ok",
			"partner": map[string]any{"name": partnerName},
			"counts":  map[string]int{"beer": countToday("beer"), "loo": countToday("loo")},
		}
		if len(posts) == 0 {
			res["state"] = "empty"
			return e.JSON(http.StatusOK, res)
		}

		post := posts[0]
		mediaURL := ""
		if media := post.GetString("media"); media != "" {
			mediaURL = fmt.Sprintf("%s/api/files/%s/%s/%s?thumb=512x512",
				baseURL(app, e), post.Collection().Id, post.Id, url.PathEscape(media))
		}
		res["post"] = map[string]any{
			"id":         post.Id,
			"type":       post.GetString("type"),
			"event_kind": post.GetString("event_kind"),
			"note":       post.GetString("note"),
			"created":    post.GetString("created"),
			"media_url":  mediaURL,
			"author":     partnerName,
		}
		return e.JSON(http.StatusOK, res)
	}
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
