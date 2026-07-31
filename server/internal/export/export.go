// Package export lets a signed-in user download everything Pear'd holds that
// is theirs: their profile, their connection memberships, and the moments
// they authored — the self-serve half of the privacy policy's deletion and
// access promise (the other half, account deletion, is still a manual email
// request until there is a route for it).
//
//	GET /api/peard/export  -> a JSON snapshot, auth required
package export

import (
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

const (
	maxConnections = 20
	maxMoments     = 10000
)

// Register binds the export route.
func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.GET("/api/peard/export", exportHandler(app)).Bind(apis.RequireAuth())
		return se.Next()
	})
}

func exportHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		userID := e.Auth.Id

		user, err := app.FindRecordById("users", userID)
		if err != nil {
			return e.NotFoundError("user not found", err)
		}

		memberships, err := app.FindRecordsByFilter("pair_members",
			"user = {:user}", "created", maxConnections, 0, dbx.Params{"user": userID})
		if err != nil {
			return e.InternalServerError("could not read your connections", err)
		}

		connections := make([]map[string]any, 0, len(memberships))
		for _, m := range memberships {
			pairID := m.GetString("pair")
			name := ""
			if pair, perr := app.FindRecordById("pairs", pairID); perr == nil {
				name = pair.GetString("name")
			}
			connections = append(connections, map[string]any{
				"id":     pairID,
				"name":   name,
				"role":   m.GetString("role"),
				"joined": m.GetString("created"),
				"muted":  m.GetBool("muted"),
			})
		}

		posts, err := app.FindRecordsByFilter("posts",
			"author = {:author}", "created", maxMoments, 0, dbx.Params{"author": userID})
		if err != nil {
			return e.InternalServerError("could not read your moments", err)
		}

		moments := make([]map[string]any, 0, len(posts))
		for _, post := range posts {
			moment := map[string]any{
				"id":         post.Id,
				"pair":       post.GetString("pair"),
				"type":       post.GetString("type"),
				"event_kind": post.GetString("event_kind"),
				"note":       post.GetString("note"),
				"created":    post.GetString("created"),
			}
			if media := post.GetString("media"); media != "" {
				moment["media_url"] = fmt.Sprintf("%s/api/files/%s/%s/%s",
					baseURL(app, e), post.Collection().Id, post.Id, url.PathEscape(media))
			}
			moments = append(moments, moment)
		}

		return e.JSON(http.StatusOK, map[string]any{
			"exported_at": time.Now().UTC().Format(time.RFC3339),
			"profile": map[string]any{
				"id":           user.Id,
				"email":        user.GetString("email"),
				"display_name": user.GetString("display_name"),
			},
			"connections": connections,
			"moments":     moments,
		})
	}
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
