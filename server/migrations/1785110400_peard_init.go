// Package migrations holds the Pear'd schema migrations (PocketBase Go migrations).
package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Pear'd initial schema:
//
//	pairs, pair_members - 1:1 pairing (join table keeps groups possible later)
//	posts               - photos & event tallies (beer/loo/custom)
//	reactions           - lightweight responses to posts
//	pair_invites        - 6-char invite codes (managed via /api/peard/pairs)
//	devices             - APNs device tokens per user
//	widget_tokens       - revocable tokens used by the WidgetKit extension
func init() {
	m.Register(func(app core.App) error {
		usersCol, err := app.FindCollectionByNameOrId("users")
		if err != nil {
			return err
		}

		// --- pairs (rules applied at the end, once pair_members exists) ---
		pairs := core.NewBaseCollection("pairs")
		pairs.Fields.Add(&core.TextField{Name: "name", Max: 80})
		if err := app.Save(pairs); err != nil {
			return err
		}

		// --- pair_members ---
		members := core.NewBaseCollection("pair_members")
		members.Fields.Add(
			&core.RelationField{Name: "pair", CollectionId: pairs.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.RelationField{Name: "user", CollectionId: usersCol.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.SelectField{Name: "role", Values: []string{"owner", "member"}, Required: true, MaxSelect: 1},
		)
		members.AddIndex("idx_pair_members_pair_user", true, "pair, user", "")
		if err := app.Save(members); err != nil {
			return err
		}

		// --- posts (rules applied at the end) ---
		posts := core.NewBaseCollection("posts")
		posts.Fields.Add(
			&core.RelationField{Name: "pair", CollectionId: pairs.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.RelationField{Name: "author", CollectionId: usersCol.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.SelectField{Name: "type", Values: []string{"photo", "event"}, Required: true, MaxSelect: 1},
			&core.TextField{Name: "event_kind", Max: 40},
			&core.TextField{Name: "note", Max: 280},
			&core.FileField{
				Name:      "media",
				MaxSelect: 1,
				MaxSize:   20 << 20,
				MimeTypes: []string{"image/jpeg", "image/png", "image/webp", "image/heic"},
				Thumbs:    []string{"256x256", "512x512"},
			},
		)
		posts.AddIndex("idx_posts_pair_created", false, "pair", "")
		if err := app.Save(posts); err != nil {
			return err
		}

		// --- reactions ---
		reactions := core.NewBaseCollection("reactions")
		reactions.Fields.Add(
			&core.RelationField{Name: "post", CollectionId: posts.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.RelationField{Name: "user", CollectionId: usersCol.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.SelectField{Name: "kind", Values: []string{"cheers", "plus_one", "heart"}, Required: true, MaxSelect: 1},
		)
		reactions.AddIndex("idx_reactions_post_user_kind", true, "post, user, kind", "")
		reactions.ListRule = types.Pointer("post.pair.pair_members_via_pair.user ?= @request.auth.id")
		reactions.ViewRule = reactions.ListRule
		reactions.CreateRule = types.Pointer("user = @request.auth.id && post.pair.pair_members_via_pair.user ?= @request.auth.id")
		reactions.DeleteRule = types.Pointer("user = @request.auth.id")
		if err := app.Save(reactions); err != nil {
			return err
		}

		// --- pair_invites (superuser-only; clients use /api/peard/pairs routes) ---
		invites := core.NewBaseCollection("pair_invites")
		invites.Fields.Add(
			&core.TextField{Name: "code", Required: true, Max: 12},
			&core.RelationField{Name: "inviter", CollectionId: usersCol.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.RelationField{Name: "invitee", CollectionId: usersCol.Id, MaxSelect: 1},
			&core.SelectField{Name: "status", Values: []string{"pending", "accepted", "expired"}, Required: true, MaxSelect: 1},
			&core.DateField{Name: "expires"},
		)
		invites.AddIndex("idx_pair_invites_code", true, "code", "")
		invites.AddIndex("idx_pair_invites_status_expires", false, "status, expires", "")
		if err := app.Save(invites); err != nil {
			return err
		}

		// --- devices ---
		devices := core.NewBaseCollection("devices")
		devices.Fields.Add(
			&core.RelationField{Name: "user", CollectionId: usersCol.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.SelectField{Name: "platform", Values: []string{"ios", "android"}, Required: true, MaxSelect: 1},
			&core.TextField{Name: "push_token", Required: true, Max: 512},
		)
		devices.AddIndex("idx_devices_push_token", true, "push_token", "")
		devices.ListRule = types.Pointer("user = @request.auth.id")
		devices.ViewRule = devices.ListRule
		devices.CreateRule = types.Pointer("user = @request.auth.id")
		devices.UpdateRule = devices.CreateRule
		devices.DeleteRule = devices.ListRule
		if err := app.Save(devices); err != nil {
			return err
		}

		// --- widget_tokens (created only via /api/peard/widget/token) ---
		wt := core.NewBaseCollection("widget_tokens")
		wt.Fields.Add(
			&core.RelationField{Name: "user", CollectionId: usersCol.Id, Required: true, CascadeDelete: true, MaxSelect: 1},
			&core.TextField{Name: "token", Required: true, Max: 128},
			&core.TextField{Name: "label", Max: 80},
			&core.BoolField{Name: "revoked"},
			&core.DateField{Name: "expires"},
		)
		wt.AddIndex("idx_widget_tokens_token", true, "token", "")
		wt.ListRule = types.Pointer("user = @request.auth.id")
		wt.ViewRule = wt.ListRule
		wt.UpdateRule = wt.ListRule
		wt.DeleteRule = wt.ListRule
		if err := app.Save(wt); err != nil {
			return err
		}

		// --- users: add display_name (name/avatar exist on the default collection) ---
		if usersCol.Fields.GetByName("display_name") == nil {
			usersCol.Fields.Add(&core.TextField{Name: "display_name", Max: 80})
			if err := app.Save(usersCol); err != nil {
				return err
			}
		}

		// --- rules that reference back-relations (saved last) ---
		pairs.ListRule = types.Pointer("pair_members_via_pair.user ?= @request.auth.id")
		pairs.ViewRule = pairs.ListRule
		if err := app.Save(pairs); err != nil {
			return err
		}

		members.ListRule = types.Pointer("user = @request.auth.id || pair.pair_members_via_pair.user ?= @request.auth.id")
		members.ViewRule = members.ListRule
		members.DeleteRule = types.Pointer("user = @request.auth.id")
		if err := app.Save(members); err != nil {
			return err
		}

		posts.ListRule = types.Pointer("pair.pair_members_via_pair.user ?= @request.auth.id")
		posts.ViewRule = posts.ListRule
		posts.CreateRule = types.Pointer("author = @request.auth.id && pair.pair_members_via_pair.user ?= @request.auth.id")
		posts.DeleteRule = types.Pointer("author = @request.auth.id")
		return app.Save(posts)
	}, func(app core.App) error {
		for _, name := range []string{"widget_tokens", "devices", "pair_invites", "reactions", "posts", "pair_members", "pairs"} {
			if col, err := app.FindCollectionByNameOrId(name); err == nil {
				if err := app.Delete(col); err != nil {
					return err
				}
			}
		}
		return nil
	})
}
