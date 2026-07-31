// Package contacts lets someone find people they already know who are on
// Pear'd, without either side's contact book ever reaching the server in the
// clear.
//
// The app hashes each contact's email addresses and phone numbers on-device
// and sends only the hashes to POST /api/peard/contacts/match. The server
// never sees a raw email or phone number that did not already belong to an
// account, and only matches against accounts that opted into
// POST /api/peard/contacts/settings's `discoverable` flag — searching your
// own contacts needs no opt-in, appearing in someone else's results does.
//
// This is not a strong privacy guarantee: unsalted SHA-256 of a phone number
// or email is reversible by brute force for anyone who can guess the input
// space (which, for a phone number, is small). It is a meaningfully better
// default than uploading contacts in the clear, not a cryptographic promise —
// documented as such in the privacy policy.
package contacts

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"strings"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// maxPhoneLength matches the users.phone column.
const maxPhoneLength = 32

// maxContactHashes bounds one match request to a large-but-real contact
// book. Without a cap, and because unsalted hashes make this endpoint an
// oracle ("is this phone number registered?"), an unbounded request is an
// invitation to enumerate the whole hash space in one call.
const maxContactHashes = 1000

// Register binds the contact-hash record hooks and the two routes.
func Register(app core.App) {
	app.OnRecordCreate("users").BindFunc(func(e *core.RecordEvent) error {
		applyContactHashes(e.Record)
		return e.Next()
	})
	app.OnRecordUpdate("users").BindFunc(func(e *core.RecordEvent) error {
		applyContactHashes(e.Record)
		return e.Next()
	})

	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		g := se.Router.Group("/api/peard/contacts")
		g.POST("/match", matchHandler(app)).Bind(apis.RequireAuth())
		g.POST("/settings", settingsHandler(app)).Bind(apis.RequireAuth())
		return se.Next()
	})
}

// applyContactHashes keeps email_hash/phone_hash in step with email/phone
// regardless of how they changed — Apple sign-in, Google sign-in, a password
// account, or the discoverability settings route below all funnel through
// the same users collection save.
func applyContactHashes(record *core.Record) {
	record.Set("email_hash", HashEmail(record.GetString("email")))
	record.Set("phone_hash", HashPhone(record.GetString("phone")))
}

func settingsHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			Discoverable bool   `json:"discoverable" form:"discoverable"`
			Phone        string `json:"phone" form:"phone"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}

		phone := strings.TrimSpace(body.Phone)
		if len(phone) > maxPhoneLength {
			phone = phone[:maxPhoneLength]
		}

		user, err := app.FindRecordById("users", e.Auth.Id)
		if err != nil {
			return e.NotFoundError("user not found", err)
		}
		user.Set("discoverable", body.Discoverable)
		user.Set("phone", phone)
		if err := app.Save(user); err != nil {
			return e.BadRequestError("failed to save", err)
		}

		return e.JSON(http.StatusOK, map[string]any{
			"discoverable": user.GetBool("discoverable"),
			"phone":        user.GetString("phone"),
		})
	}
}

func matchHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			Hashes []string `json:"hashes"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("invalid request body", err)
		}
		if len(body.Hashes) > maxContactHashes {
			body.Hashes = body.Hashes[:maxContactHashes]
		}

		unique := dedupeNonEmpty(body.Hashes)
		filter, params := matchFilter(unique)
		if filter == "" {
			return e.JSON(http.StatusOK, map[string]any{"matches": []map[string]any{}})
		}

		users, err := app.FindRecordsByFilter("users", filter, "", maxContactHashes, 0, params)
		if err != nil {
			return e.InternalServerError("match failed", err)
		}

		wasSubmitted := make(map[string]bool, len(unique))
		for _, h := range unique {
			wasSubmitted[h] = true
		}

		matches := make([]map[string]any, 0, len(users))
		for _, u := range users {
			if u.Id == e.Auth.Id {
				continue
			}
			matches = append(matches, map[string]any{
				"id":           u.Id,
				"display_name": u.GetString("display_name"),
				"avatar":       u.GetString("avatar"),
				// Which of the caller's own submitted hashes this account
				// matched on — echoing it back reveals nothing the caller
				// did not already know, since it is the caller's own hash,
				// but it is what lets the app show "this is your contact
				// Alex" instead of an anonymous result it cannot act on.
				"hash": matchedHash(u, wasSubmitted),
			})
		}
		return e.JSON(http.StatusOK, map[string]any{"matches": matches})
	}
}

func matchedHash(user *core.Record, submitted map[string]bool) string {
	if h := user.GetString("email_hash"); h != "" && submitted[h] {
		return h
	}
	if h := user.GetString("phone_hash"); h != "" && submitted[h] {
		return h
	}
	return ""
}

func dedupeNonEmpty(hashes []string) []string {
	seen := make(map[string]bool, len(hashes))
	out := make([]string, 0, len(hashes))
	for _, h := range hashes {
		h = strings.TrimSpace(h)
		if h == "" || seen[h] {
			continue
		}
		seen[h] = true
		out = append(out, h)
	}
	return out
}

// matchFilter builds "discoverable = true && (email_hash = {:h0} ||
// phone_hash = {:h0} || ...)" for the given (already deduplicated) hashes —
// PocketBase's filter language has no IN-list operator for a plain text
// field, only for multi-valued relations.
func matchFilter(hashes []string) (string, dbx.Params) {
	if len(hashes) == 0 {
		return "", nil
	}
	clauses := make([]string, 0, len(hashes))
	params := dbx.Params{}
	for i, h := range hashes {
		key := fmt.Sprintf("h%d", i)
		clauses = append(clauses, fmt.Sprintf("email_hash = {:%s} || phone_hash = {:%s}", key, key))
		params[key] = h
	}
	return "discoverable = true && (" + strings.Join(clauses, " || ") + ")", params
}

// NormaliseEmail lowercases and trims, so the same address hashes the same
// way regardless of capitalisation or stray whitespace.
func NormaliseEmail(email string) string {
	return strings.ToLower(strings.TrimSpace(email))
}

// NormalisePhone keeps digits only.
//
// Deliberately simple: no libphonenumber, no country-code inference. A
// number saved locally without its country code (a UK contact saved as
// "07888 291038" rather than "+44 7888 291038") will not match its owner's
// account. That is a real, known gap — documented in the privacy policy
// rather than solved with a phone-parsing dependency neither the app nor the
// server otherwise needs.
func NormalisePhone(phone string) string {
	var b strings.Builder
	for _, r := range phone {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// HashEmail and HashPhone are what both the server (hashing an account's own
// identity, in the record hooks above) and the app (hashing a contact before
// it ever leaves the device) must compute identically. Namespaced so an
// email and a phone number that happen to normalise to the same bytes can
// never collide.
func HashEmail(email string) string {
	normalised := NormaliseEmail(email)
	if normalised == "" {
		return ""
	}
	return hash("email:" + normalised)
}

func HashPhone(phone string) string {
	normalised := NormalisePhone(phone)
	if normalised == "" {
		return ""
	}
	return hash("phone:" + normalised)
}

func hash(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}
