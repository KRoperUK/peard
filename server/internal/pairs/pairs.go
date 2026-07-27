// Package pairs implements Pear'd pairing: invite codes, accept and leave.
//
// Routes (all require auth):
//   POST /api/peard/pairs/invite  -> { code, deep_link, expires }
//   POST /api/peard/pairs/accept  { code } -> { pair }
//   POST /api/peard/pairs/leave   -> { ok }
//
// MVP constraint: one pair per user. The pair_members join table is
// many-to-many so groups can be introduced later without a data migration.
package pairs

import (
	"crypto/rand"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

const inviteTTL = 7 * 24 * time.Hour

// Register binds the pairing routes and the invite-expiry cron job.
func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		g := se.Router.Group("/api/peard/pairs")
		g.POST("/invite", inviteHandler(app)).Bind(apis.RequireAuth())
		g.POST("/accept", acceptHandler(app)).Bind(apis.RequireAuth())
		g.POST("/leave", leaveHandler(app)).Bind(apis.RequireAuth())
		return se.Next()
	})

	// Sweep stale invites every 15 minutes.
	app.Cron().MustAdd("peard-expire-invites", "*/15 * * * *", func() {
		invites, err := app.FindRecordsByFilter(
			"pair_invites",
			"status = 'pending' && expires < {:now}",
			"", 500, 0,
			dbx.Params{"now": types.NowDateTime().String()},
		)
		if err != nil {
			return
		}
		for _, inv := range invites {
			inv.Set("status", "expired")
			_ = app.Save(inv)
		}
	})
}

func inviteHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		if err := requireNoPair(app, e.Auth.Id); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		col, err := app.FindCollectionByNameOrId("pair_invites")
		if err != nil {
			return e.InternalServerError("pair_invites collection missing", err)
		}
		inv := core.NewRecord(col)
		code := newCode(6)
		inv.Set("code", code)
		inv.Set("inviter", e.Auth.Id)
		inv.Set("status", "pending")
		inv.Set("expires", time.Now().Add(inviteTTL).UTC().Format(types.DefaultDateLayout))
		if err := app.Save(inv); err != nil {
			return e.InternalServerError("failed to create invite", err)
		}
		return e.JSON(http.StatusOK, map[string]any{
			"code":      code,
			"expires":   inv.GetString("expires"),
			"deep_link": "peard://pair/" + code,
		})
	}
}

func acceptHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			Code string `json:"code" form:"code"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}
		code := strings.ToUpper(strings.TrimSpace(body.Code))
		if code == "" {
			return e.BadRequestError("code is required", nil)
		}

		inv, err := app.FindFirstRecordByFilter("pair_invites",
			"code = {:code} && status = 'pending'", dbx.Params{"code": code})
		if err != nil || inv == nil {
			return e.NotFoundError("invite not found or already used", err)
		}
		if exp := inv.GetDateTime("expires"); !exp.IsZero() && exp.Time().Before(time.Now()) {
			inv.Set("status", "expired")
			_ = app.Save(inv)
			return e.BadRequestError("invite expired", nil)
		}
		if inv.GetString("inviter") == e.Auth.Id {
			return e.BadRequestError("you cannot pear with yourself", nil)
		}
		if err := requireNoPair(app, e.Auth.Id); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		if err := requireNoPair(app, inv.GetString("inviter")); err != nil {
			return e.BadRequestError("your partner has already pear'd with someone else", nil)
		}

		var pairID string
		err = app.RunInTransaction(func(txApp core.App) error {
			pairsCol, err := txApp.FindCollectionByNameOrId("pairs")
			if err != nil {
				return err
			}
			pair := core.NewRecord(pairsCol)
			if err := txApp.Save(pair); err != nil {
				return err
			}
			pairID = pair.Id

			membersCol, err := txApp.FindCollectionByNameOrId("pair_members")
			if err != nil {
				return err
			}
			for _, m := range []struct{ user, role string }{
				{inv.GetString("inviter"), "owner"},
				{e.Auth.Id, "member"},
			} {
				mem := core.NewRecord(membersCol)
				mem.Set("pair", pair.Id)
				mem.Set("user", m.user)
				mem.Set("role", m.role)
				if err := txApp.Save(mem); err != nil {
					return err
				}
			}

			inv.Set("status", "accepted")
			inv.Set("invitee", e.Auth.Id)
			return txApp.Save(inv)
		})
		if err != nil {
			return e.InternalServerError("failed to create pair", err)
		}
		return e.JSON(http.StatusOK, map[string]any{"pair": pairID})
	}
}

func leaveHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		mem, err := app.FindFirstRecordByFilter("pair_members",
			"user = {:user}", dbx.Params{"user": e.Auth.Id})
		if err != nil || mem == nil {
			return e.NotFoundError("you are not pear'd with anyone", err)
		}
		pairID := mem.GetString("pair")
		if err := app.Delete(mem); err != nil {
			return e.InternalServerError("failed to leave pair", err)
		}
		// Delete the pair once empty (cascades to posts/reactions).
		remaining, _ := app.FindRecordsByFilter("pair_members",
			"pair = {:pair}", "", 1, 0, dbx.Params{"pair": pairID})
		if len(remaining) == 0 {
			if pair, err := app.FindRecordById("pairs", pairID); err == nil {
				_ = app.Delete(pair)
			}
		}
		return e.JSON(http.StatusOK, map[string]any{"ok": true})
	}
}

// requireNoPair enforces the MVP one-pair-per-user rule.
func requireNoPair(app core.App, userID string) error {
	existing, err := app.FindFirstRecordByFilter("pair_members",
		"user = {:user}", dbx.Params{"user": userID})
	if err == nil && existing != nil {
		return errors.New("already pear'd (MVP supports one pair per user)")
	}
	return nil
}

// Invite codes avoid visually ambiguous characters (no I, L, O, 0, 1).
const codeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

func newCode(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = codeAlphabet[int(b[i])%len(codeAlphabet)]
	}
	return string(b)
}
