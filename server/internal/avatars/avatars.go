// Package avatars sets and clears profile photos, for a person and for a
// connection.
//
//	POST   /api/peard/profile/avatar      multipart: avatar        -> { id, display_name, email, avatar }
//	DELETE /api/peard/profile/avatar                              -> { id, display_name, email, avatar: "" }
//	POST   /api/peard/connections/avatar  multipart: pair, avatar  -> { pair, avatar }
//	DELETE /api/peard/connections/avatar?pair=…                    -> { pair, avatar: "" }
//
// Routes rather than collection writes, for the same reason `internal/profile`
// is a route: `users.UpdateRule` is `id = @request.auth.id`, which is the whole
// record. Narrowing it to one field is not expressible in a rule, and a PATCH
// that can also carry `email` or `emailVisibility` is a wider grant than "let me
// pick a picture". `pairs.UpdateRule` already admits any member, so the group
// photo could in principle be a collection PATCH — it is here anyway so that
// both live behind one validation path and one response shape.
//
// Clearing is a DELETE rather than an empty upload. PocketBase deletes the
// previous file when the field is set to nothing, so an accidental empty POST
// would silently erase a photo; making removal its own verb means it cannot
// happen by omission.
package avatars

import (
	"errors"
	"net/http"
	"strings"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/filesystem"
)

// fieldName is the file field on both `users` and `pairs`.
const fieldName = "avatar"

// maxUploadBytes bounds what the route will accept before PocketBase's own
// field-level MaxSize does. Rejecting early means a 20 MB HEIC is refused with a
// readable message rather than a validation error naming a field.
const maxUploadBytes int64 = 8 << 20

// Register binds the avatar routes.
func Register(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		profile := se.Router.Group("/api/peard/profile/avatar")
		profile.POST("", setProfileAvatar(app)).Bind(apis.RequireAuth())
		profile.DELETE("", clearProfileAvatar(app)).Bind(apis.RequireAuth())

		connection := se.Router.Group("/api/peard/connections/avatar")
		connection.POST("", setConnectionAvatar(app)).Bind(apis.RequireAuth())
		connection.DELETE("", clearConnectionAvatar(app)).Bind(apis.RequireAuth())
		return se.Next()
	})
}

func setProfileAvatar(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		user, err := app.FindRecordById("users", e.Auth.Id)
		if err != nil {
			return e.NotFoundError("user not found", err)
		}
		file, err := uploadedAvatar(e)
		if err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		user.Set(fieldName, []*filesystem.File{file})
		if err := app.Save(user); err != nil {
			return e.BadRequestError("that image could not be saved", err)
		}
		return e.JSON(http.StatusOK, presentUser(user))
	}
}

func clearProfileAvatar(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		user, err := app.FindRecordById("users", e.Auth.Id)
		if err != nil {
			return e.NotFoundError("user not found", err)
		}
		user.Set(fieldName, nil)
		if err := app.Save(user); err != nil {
			return e.InternalServerError("failed to remove your photo", err)
		}
		return e.JSON(http.StatusOK, presentUser(user))
	}
}

func setConnectionAvatar(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		// The pair id travels as a multipart form value, so it cannot be read with
		// BindBody: that would consume the body the file is in.
		pairID := strings.TrimSpace(e.Request.FormValue("pair"))
		pair, err := memberPair(app, pairID, e.Auth.Id)
		if err != nil {
			return responseFor(e, err)
		}
		file, err := uploadedAvatar(e)
		if err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		pair.Set(fieldName, []*filesystem.File{file})
		if err := app.Save(pair); err != nil {
			return e.BadRequestError("that image could not be saved", err)
		}
		return e.JSON(http.StatusOK, presentPair(pair))
	}
}

func clearConnectionAvatar(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		// A DELETE carries no body, so the connection is named in the query.
		pairID := strings.TrimSpace(e.Request.URL.Query().Get("pair"))
		pair, err := memberPair(app, pairID, e.Auth.Id)
		if err != nil {
			return responseFor(e, err)
		}
		pair.Set(fieldName, nil)
		if err := app.Save(pair); err != nil {
			return e.InternalServerError("failed to remove the photo", err)
		}
		return e.JSON(http.StatusOK, presentPair(pair))
	}
}

// errNotMember and errNoPair separate "you asked wrong" from "you may not",
// so the handlers can answer 400/403/404 without repeating the lookup.
var (
	errNoPair    = errors.New("pair is required")
	errNotMember = errors.New("you are not a member of that connection")
)

// memberPair resolves a connection the caller actually belongs to.
//
// Any member may set the photo, matching rename: a connection's name and face
// are shared property, and a group whose only owner has left would otherwise be
// stuck with whatever picture it had.
func memberPair(app core.App, pairID, userID string) (*core.Record, error) {
	if pairID == "" {
		return nil, errNoPair
	}
	member, err := app.FindFirstRecordByFilter("pair_members",
		"pair = {:pair} && user = {:user}",
		dbx.Params{"pair": pairID, "user": userID})
	if err != nil || member == nil {
		return nil, errNotMember
	}
	pair, err := app.FindRecordById("pairs", pairID)
	if err != nil {
		return nil, errNotMember
	}
	return pair, nil
}

func responseFor(e *core.RequestEvent, err error) error {
	switch {
	case errors.Is(err, errNoPair):
		return e.BadRequestError(err.Error(), nil)
	case errors.Is(err, errNotMember):
		return e.ForbiddenError(err.Error(), nil)
	default:
		return e.InternalServerError("could not read that connection", err)
	}
}

// uploadedAvatar reads exactly one file from the `avatar` form field.
func uploadedAvatar(e *core.RequestEvent) (*filesystem.File, error) {
	files, err := e.FindUploadedFiles(fieldName)
	if err != nil || len(files) == 0 {
		return nil, errors.New("attach an image in the avatar field")
	}
	file := files[0]
	if file.Size > maxUploadBytes {
		return nil, errors.New("that image is too large; 8 MB is the limit")
	}
	return file, nil
}

func presentUser(user *core.Record) map[string]any {
	return map[string]any{
		"id":           user.Id,
		"display_name": user.GetString("display_name"),
		"email":        user.GetString("email"),
		"avatar":       user.GetString(fieldName),
	}
}

func presentPair(pair *core.Record) map[string]any {
	return map[string]any{
		"pair":   pair.Id,
		"avatar": pair.GetString(fieldName),
	}
}
