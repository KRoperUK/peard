// Package export lets a signed-in user download everything Pear'd holds that
// is theirs: their profile, their connection memberships and invites, the
// moments they authored, the reactions they left, the custom moment kinds they
// added, and the devices, widget tokens and Live Activities registered to them
// — the self-serve access half of the privacy policy's promise (the other half
// is DELETE /api/peard/account in internal/profile).
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

// pageSize is how many rows each query fetches at a time. The export used to
// stop at 10,000 moments without saying so; it now pages through every row, so
// a long history comes out whole. The page bounds each query, not the export.
var pageSize = 500

// mediaNote travels in the payload. Photos stay as links rather than being
// bundled into a zip (a possible follow-up): a JSON body keeps the route cheap,
// and the note makes the links' shelf life plain.
const mediaNote = "Photo links carry a temporary access token and stop working about 30 minutes after this export. Re-export to get fresh ones. The same goes for your profile photo link."

// tokenNote says why tokens appear only in part.
const tokenNote = "Push tokens are shown masked (last 6 characters only). A full token is the address Pear'd's server uses to send notifications to that device; it is of no use outside the app, so it is kept out of a file that may be shared or stored anywhere. Widget token secrets and invite codes are left out for the same reason."

// Register binds the export route.
func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.GET("/api/peard/export", exportHandler(app)).Bind(apis.RequireAuth())
		return se.Next()
	})
}

// eachRecord pages through every record in collection matching filter, oldest
// first, calling fn for each one. The id tiebreak keeps the pages stable when
// several rows share a created timestamp.
func eachRecord(app core.App, collection, filter string, params dbx.Params, fn func(*core.Record)) error {
	for offset := 0; ; offset += pageSize {
		records, err := app.FindRecordsByFilter(collection, filter, "created,id", pageSize, offset, params)
		if err != nil {
			return err
		}
		for _, r := range records {
			fn(r)
		}
		if len(records) < pageSize {
			return nil
		}
	}
}

// maskToken keeps only the tail of a push token: enough to tell two devices
// apart in the export, not enough to address either.
func maskToken(token string) string {
	const keep = 6
	if len(token) <= keep {
		return strings.Repeat("•", len(token))
	}
	return "…" + token[len(token)-keep:]
}

func exportHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		userID := e.Auth.Id
		mine := dbx.Params{"user": userID}

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
		base := baseURL(app, e)

		// email_hash and phone_hash are left out: they are one-way digests of
		// the email and phone below, kept only so contact matching never has to
		// compare plaintext, and say nothing the plain values do not.
		profile := map[string]any{
			"id":            user.Id,
			"email":         user.GetString("email"),
			"display_name":  user.GetString("display_name"),
			"name":          user.GetString("name"),
			"phone":         user.GetString("phone"),
			"contact_email": user.GetString("contact_email"),
			"discoverable":  user.GetBool("discoverable"),
			"created":       user.GetString("created"),
			"updated":       user.GetString("updated"),
		}
		if avatar := user.GetString("avatar"); avatar != "" {
			profile["avatar"] = avatar
			profile["avatar_url"] = fileURL(base, user, avatar, fileToken)
		}

		connections := []map[string]any{}
		err = eachRecord(app, "pair_members", "user = {:user}", mine, func(m *core.Record) {
			pairID := m.GetString("pair")
			name := ""
			if pair, perr := app.FindRecordById("pairs", pairID); perr == nil {
				name = pair.GetString("name")
			}
			connections = append(connections, map[string]any{
				"id":           pairID,
				"name":         name,
				"role":         m.GetString("role"),
				"joined":       m.GetString("created"),
				"muted":        m.GetBool("muted"),
				"last_seen_at": m.GetString("last_seen_at"),
			})
		})
		if err != nil {
			return e.InternalServerError("could not read your connections", err)
		}

		invites := []map[string]any{}
		err = eachRecord(app, "pair_invites", "inviter = {:user} || invitee = {:user}", mine, func(inv *core.Record) {
			direction := "received"
			if inv.GetString("inviter") == userID {
				direction = "sent"
			}
			invites = append(invites, map[string]any{
				"id":        inv.Id,
				"direction": direction,
				"pair":      inv.GetString("pair"),
				"status":    inv.GetString("status"),
				"created":   inv.GetString("created"),
				"expires":   inv.GetString("expires"),
			})
		})
		if err != nil {
			return e.InternalServerError("could not read your invites", err)
		}

		moments := []map[string]any{}
		err = eachRecord(app, "posts", "author = {:user}", mine, func(post *core.Record) {
			moment := map[string]any{
				"id":          post.Id,
				"pair":        post.GetString("pair"),
				"type":        post.GetString("type"),
				"event_kind":  post.GetString("event_kind"),
				"note":        post.GetString("note"),
				"created":     post.GetString("created"),
				"happened_at": post.GetString("happened_at"),
				"rewound":     post.GetBool("rewound"),
			}
			if media := post.GetString("media"); media != "" {
				moment["media_url"] = fileURL(base, post, media, fileToken)
			}
			moments = append(moments, moment)
		})
		if err != nil {
			return e.InternalServerError("could not read your moments", err)
		}

		reactions := []map[string]any{}
		err = eachRecord(app, "reactions", "user = {:user}", mine, func(r *core.Record) {
			reactions = append(reactions, map[string]any{
				"id":      r.Id,
				"moment":  r.GetString("post"),
				"kind":    r.GetString("kind"),
				"created": r.GetString("created"),
			})
		})
		if err != nil {
			return e.InternalServerError("could not read your reactions", err)
		}

		kinds := []map[string]any{}
		err = eachRecord(app, "moment_kinds", "created_by = {:user}", mine, func(k *core.Record) {
			kinds = append(kinds, map[string]any{
				"id":      k.Id,
				"pair":    k.GetString("pair"),
				"slug":    k.GetString("slug"),
				"emoji":   k.GetString("emoji"),
				"label":   k.GetString("label"),
				"created": k.GetString("created"),
			})
		})
		if err != nil {
			return e.InternalServerError("could not read your moment kinds", err)
		}

		devices := []map[string]any{}
		err = eachRecord(app, "devices", "user = {:user}", mine, func(d *core.Record) {
			device := map[string]any{
				"id":         d.Id,
				"platform":   d.GetString("platform"),
				"created":    d.GetString("created"),
				"push_token": maskToken(d.GetString("push_token")),
			}
			if start := d.GetString("activity_start_token"); start != "" {
				device["activity_start_token"] = maskToken(start)
			}
			devices = append(devices, device)
		})
		if err != nil {
			return e.InternalServerError("could not read your devices", err)
		}

		widgetTokens := []map[string]any{}
		err = eachRecord(app, "widget_tokens", "user = {:user}", mine, func(w *core.Record) {
			widgetTokens = append(widgetTokens, map[string]any{
				"id":      w.Id,
				"label":   w.GetString("label"),
				"created": w.GetString("created"),
				"expires": w.GetString("expires"),
				"revoked": w.GetBool("revoked"),
			})
		})
		if err != nil {
			return e.InternalServerError("could not read your widget tokens", err)
		}

		activities := []map[string]any{}
		err = eachRecord(app, "live_activities", "user = {:user}", mine, func(a *core.Record) {
			activities = append(activities, map[string]any{
				"id":      a.Id,
				"pair":    a.GetString("pair"),
				"created": a.GetString("created"),
				"expires": a.GetString("expires"),
			})
		})
		if err != nil {
			return e.InternalServerError("could not read your live activities", err)
		}

		return e.JSON(http.StatusOK, map[string]any{
			"exported_at":     time.Now().UTC().Format(time.RFC3339),
			"media_note":      mediaNote,
			"token_note":      tokenNote,
			"profile":         profile,
			"connections":     connections,
			"invites":         invites,
			"moments":         moments,
			"reactions":       reactions,
			"moment_kinds":    kinds,
			"devices":         devices,
			"widget_tokens":   widgetTokens,
			"live_activities": activities,
		})
	}
}

// fileURL links to one of record's protected files, carrying the caller's
// short-lived file token so the link opens.
func fileURL(base string, record *core.Record, name, fileToken string) string {
	link := fmt.Sprintf("%s/api/files/%s/%s/%s",
		base, record.Collection().Id, record.Id, url.PathEscape(name))
	if fileToken != "" {
		link += "?token=" + fileToken
	}
	return link
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
