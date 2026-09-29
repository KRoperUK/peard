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
// What is stored is keyed. With PEARD_CONTACT_HASH_KEY set, an account's
// email_hash and phone_hash hold HMAC-SHA256(key, sha256-hex) rather than the
// plain SHA-256, and the match route applies the same HMAC to each submitted
// hash before looking it up. The app is unchanged: it still sends plain
// SHA-256, which is what keeps the scheme working with every build already
// installed.
//
// What the key protects: the database. A plain SHA-256 of a phone number can
// be reversed by trying every number, and phone numbers are a small space, so
// a leaked users table used to be a leaked list of phone numbers and emails.
// Keyed, the hashes cannot be reversed without the key as well, and the key
// lives in the server's environment, not its database.
//
// What it does not protect: the hashes still reach the server unkeyed (over
// TLS), so whoever runs the server sees each submitted SHA-256 and could
// brute-force those just as before. Closing that needs private set
// intersection, which is out of scope. The match route is also still an
// oracle for "is this number registered and discoverable?", bounded by
// maxContactHashes and the rate limits, not by the key.
//
// Adding or rotating the key needs nothing else: every boot recomputes every
// account's hashes from its stored email and phone with the current key. With
// no key the plain SHA-256 is stored, exactly as before, and the server warns
// once at boot.
package contacts

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"os"
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

// hashKeyEnv names the server secret stored hashes are keyed with.
const hashKeyEnv = "PEARD_CONTACT_HASH_KEY"

// hashKey is read on every use rather than once at Register, so the boot
// re-key, the record hooks and the match route can never disagree about it.
// The environment does not change under a running process, so in production
// it is the same key every time.
func hashKey() []byte {
	return []byte(strings.TrimSpace(os.Getenv(hashKeyEnv)))
}

// keyed turns a plain SHA-256 hex digest into what is stored and looked up:
// HMAC-SHA256 under the server key, hex-encoded, or the digest unchanged when
// there is no key. Empty stays empty, so "no phone" never matches anything.
func keyed(digest string) string {
	key := hashKey()
	if digest == "" || len(key) == 0 {
		return digest
	}
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(digest))
	return hex.EncodeToString(mac.Sum(nil))
}

// Register binds the contact-hash record hooks, the boot re-key and the two
// routes.
func Register(app core.App) {
	app.OnBootstrap().BindFunc(func(e *core.BootstrapEvent) error {
		if err := e.Next(); err != nil {
			return err
		}
		if len(hashKey()) == 0 {
			e.App.Logger().Warn(hashKeyEnv + " is not set: contact hashes are stored as plain SHA-256, which anyone holding a copy of the database could reverse for phone numbers")
		}
		// A failed re-key leaves some accounts unmatchable until the next
		// boot, which is not worth refusing to start over.
		changed, err := rekeyAll(e.App)
		if err != nil {
			e.App.Logger().Error("contact hash re-key failed", "error", err, "changed", changed)
		} else if changed > 0 {
			e.App.Logger().Info("contact hashes re-keyed", "changed", changed)
		}
		return nil
	})

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
	record.Set("email_hash", storedEmailHash(record))
	record.Set("phone_hash", storedPhoneHash(record))
}

func storedEmailHash(record *core.Record) string { return keyed(HashEmail(MatchableEmail(record))) }
func storedPhoneHash(record *core.Record) string { return keyed(HashPhone(record.GetString("phone"))) }

// rekeyPage bounds how many accounts rekeyAll holds at once.
const rekeyPage = 500

// rekeyAll recomputes every account's stored hashes with the current key and
// writes the ones that changed, returning how many did. That is what makes
// adding, rotating or removing the key a restart and nothing more: the
// plaintext email and phone are on the record, so no old key is needed.
//
// A direct column update rather than app.Save. These two columns are derived
// data, not an edit to the account: a Save would bump every user's `updated`,
// fire realtime events and every users hook, and re-validate whole records,
// so one stale row somewhere could stop the rest being re-keyed. The only hook
// that cares about these columns is applyContactHashes, which would compute
// exactly the values written here.
//
// Under `serve` this runs after bootstrap but before pending migrations. On a
// data directory that predates the contacts migration there is nothing to
// re-key yet, and the accounts that migration backfills go through the record
// hooks, which key them.
func rekeyAll(app core.App) (int, error) {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil || users.Fields.GetByName("email_hash") == nil || users.Fields.GetByName("phone_hash") == nil {
		return 0, nil
	}
	changed := 0
	for offset := 0; ; offset += rekeyPage {
		records, err := app.FindRecordsByFilter("users", "", "id", rekeyPage, offset)
		if err != nil {
			return changed, err
		}
		for _, r := range records {
			email, phone := storedEmailHash(r), storedPhoneHash(r)
			if email == r.GetString("email_hash") && phone == r.GetString("phone_hash") {
				continue
			}
			if _, err := app.DB().Update("users",
				dbx.Params{"email_hash": email, "phone_hash": phone},
				dbx.HashExp{"id": r.Id}).Execute(); err != nil {
				return changed, err
			}
			changed++
		}
		if len(records) < rekeyPage {
			return changed, nil
		}
	}
}

// MatchableEmail is the address to hash for contact matching: whatever the user
// nominated, else the account's own.
//
// They differ for Sign in with Apple accounts that chose to hide their address.
// The relay Apple issues — `something@privaterelay.appleid.com` — is generated
// per app, per account, so it has never been anybody's address and cannot be in
// anybody's contacts. Hashing it is hashing a value with no possible match.
func MatchableEmail(record *core.Record) string {
	if nominated := strings.TrimSpace(record.GetString("contact_email")); nominated != "" {
		return nominated
	}
	return record.GetString("email")
}

// appleRelayDomain is the suffix Apple issues hidden addresses under.
const appleRelayDomain = "@privaterelay.appleid.com"

// IsAppleRelayEmail reports whether an address is one Apple generated to hide
// somebody's real one.
func IsAppleRelayEmail(email string) bool {
	return strings.HasSuffix(strings.ToLower(strings.TrimSpace(email)), appleRelayDomain)
}

func settingsHandler(app core.App) func(e *core.RequestEvent) error {
	return func(e *core.RequestEvent) error {
		var body struct {
			Discoverable bool   `json:"discoverable" form:"discoverable"`
			Phone        string `json:"phone" form:"phone"`
			ContactEmail string `json:"contact_email" form:"contact_email"`
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
		// Normalised the same way the hash normalises, so what is stored is
		// what will be matched — a stored address that differs from its own
		// hash by a capital letter is a bug nobody would ever see.
		contactEmail := NormaliseEmail(body.ContactEmail)
		if contactEmail != "" && !strings.Contains(contactEmail, "@") {
			return e.BadRequestError("that does not look like an email address", nil)
		}
		// Nominating the relay address itself is the one thing that cannot
		// help: it is the address this field exists to work around.
		if IsAppleRelayEmail(contactEmail) {
			return e.BadRequestError("that is a private relay address — use one people have for you", nil)
		}

		// The phone number is only held for discovery, so turning discovery
		// off drops it (and, via the record hook, its hash) rather than
		// keeping it for next time.
		if !body.Discoverable {
			phone = ""
		}
		user.Set("discoverable", body.Discoverable)
		user.Set("phone", phone)
		user.Set("contact_email", contactEmail)
		if err := app.Save(user); err != nil {
			return e.BadRequestError("failed to save", err)
		}

		return e.JSON(http.StatusOK, map[string]any{
			"discoverable": user.GetBool("discoverable"),
			"phone":        user.GetString("phone"),
			// Echoed so the app can show what is actually stored rather than
			// what was typed, and so it knows whether to offer the field at
			// all.
			"contact_email":  user.GetString("contact_email"),
			"email_is_relay": IsAppleRelayEmail(user.GetString("email")),
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

		// Look up what is stored — the keyed form — and remember which
		// submitted hash each came from, so the response can echo the
		// caller's own value rather than one only the server can compute.
		submittedFor := make(map[string]string, len(unique))
		lookup := make([]string, 0, len(unique))
		for _, h := range unique {
			k := keyed(h)
			submittedFor[k] = h
			lookup = append(lookup, k)
		}
		filter, params := matchFilter(lookup)
		if filter == "" {
			return e.JSON(http.StatusOK, map[string]any{"matches": []map[string]any{}})
		}

		users, err := app.FindRecordsByFilter("users", filter, "", maxContactHashes, 0, params)
		if err != nil {
			return e.InternalServerError("match failed", err)
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
				"hash": matchedHash(u, submittedFor),
			})
		}
		return e.JSON(http.StatusOK, map[string]any{"matches": matches})
	}
}

// matchedHash maps the stored hash an account matched on back to the caller's
// submitted one.
func matchedHash(user *core.Record, submittedFor map[string]string) string {
	if h := user.GetString("email_hash"); h != "" && submittedFor[h] != "" {
		return submittedFor[h]
	}
	if h := user.GetString("phone_hash"); h != "" && submittedFor[h] != "" {
		return submittedFor[h]
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
// identity, in the record hooks above, before keying it) and the app (hashing a contact before
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
