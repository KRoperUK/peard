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

		// posts.media is a protected file field, so a bare URL is a 404 to
		// everybody including its owner. The links below carry a file token, so
		// the export is a thing somebody can actually open — which is the point
		// of it, and a commitment the privacy policy makes.
		//
		// The token expires (30 minutes), so the links do too. That is stated
		// in the payload rather than left to be discovered: an export whose
		// photos quietly stop resolving next week is worse than one that says
		// when to use it.
		fileToken, ferr := user.NewFileToken()
		if ferr != nil {
			fileToken = ""
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
				mediaURL := fmt.Sprintf("%s/api/files/%s/%s/%s",
					baseURL(app, e), post.Collection().Id, post.Id, url.PathEscape(media))
				if fileToken != "" {
					mediaURL += "?token=" + fileToken
				}
				moment["media_url"] = mediaURL
			}
			moments = append(moments, moment)
		}

		return e.JSON(http.StatusOK, map[string]any{
			"exported_at": time.Now().UTC().Format(time.RFC3339),
			"media_note":  "Photo links carry a temporary access token and stop working about 30 minutes after this export. Re-export to get fresh ones.",
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
