# Pear'd wire contract

Canonical description of the JSON exchanged between the iOS app (`ios/`) and the
PocketBase server (`server/`). This document replaces `shared/types.ts`, which
was deleted when the Expo client was retired — there is no longer a TypeScript
client to share types with.

The Swift mirror of everything below lives in
`ios/PeardCore/Sources/PeardCore/Models.swift`, and the round-trip properties
are enforced by `ios/PeardCore/Tests/PeardCoreTests/ModelRoundTripTests.swift`.

## Dates

Every timestamp is a string in the PocketBase format, always UTC:

```
yyyy-MM-dd HH:mm:ss.SSS'Z'      e.g. 2026-07-28 21:30:15.250Z
```

The client also parses the millisecond-less variant `yyyy-MM-dd HH:mm:ss'Z'`
but always emits milliseconds. `created` and `updated` are `autodate` fields;
the original collections gained them in
`migrations/1785196800_peard_timestamps.go`, and `moment_kinds` was created with
them in `migrations/1785283200_peard_groups_and_moments.go`. Records written
before the first of those carry an empty string, which the client decodes as
"no timestamp" rather than failing.

## Unknown enumerated values

`type`, `state`, `role` and `kind` are open: a value outside the listed set is
preserved verbatim by the client and re-encoded unchanged. Adding a new value
server-side cannot break an installed app.

## Who can see what

One rule, everywhere: **you can read another person's information only if you
share a connection with them.** It is enforced by collection rules rather than by
the client, so it holds for anything speaking to the API.

| Collection | List / view rule |
|---|---|
| `users` | `id = @request.auth.id` — you only ever read *yourself* |
| `pairs` | you are a member |
| `pair_members` | your own row, or a row in a connection you are in |
| `posts` | the post's connection is one you are in |
| `reactions` | the reacted-to post's connection is one you are in |
| `moment_kinds` | the kind's connection is one you are in |
| `devices`, `widget_tokens` | `user = @request.auth.id` |

Every one of those is prefixed with `@request.auth.id != "" && (…)`, which is not
decoration. The membership clauses scope through a back-relation such as
`pair_members_via_pair.user ?= @request.auth.id`, and PocketBase compiles that to
a LEFT JOIN — so for a connection with **no members** the joined user is NULL, and
comparing NULL against the empty auth id of an *unauthenticated* request matched.
A memberless connection, plus its posts, reactions and custom moments, was
readable with no `Authorization` header at all. A signed-in stranger was never
affected, since NULL never equals a real id.

Memberless connections are not exotic: leaving deletes a `pair_members` row and
nothing deletes the connection behind it, so the last person to leave published
the whole shared timeline, notes included. The guard rejects the empty case before
the join is considered. The parentheses matter too — several rules are top-level
`||`, and `a != "" && b || c` binds as `(a != "" && b) || c`, which would leave the
hole open through `c`.

Because none of this is expressible per-field, two things are routes rather than
collection access: `GET /api/peard/connections` (member display names, which the
`users` rule hides) and the avatar endpoints (one field of a record the caller may
otherwise rewrite entirely). `server/internal/access` holds the suite that proves
the whole property against the real schema, including that a co-member *does* get
names and avatars while never getting an email address.

## Collection records

### `posts`

| Field | Type | Notes |
|---|---|---|
| `id` | string | 15-char PocketBase id |
| `pair` | string | relation → `pairs` |
| `author` | string | relation → `users` |
| `type` | `"photo"` \| `"event"` | open |
| `event_kind` | string | free text, max 40; `beer`, `loo`, `coffee` are built in, anything else is a custom moment (see `moment_kinds`) |
| `note` | string | max 280, `""` when unset |
| `media` | string | filename, `""` when unset |
| `client_id` | string | max 60, `""` when unset. The sender's own id for the write, carried so a retry cannot duplicate a moment — see below |
| `created` | date | |
| `updated` | date | |

Thumbnail URL: `GET /api/files/posts/{id}/{media}?thumb=512x512`.

`client_id` exists because the app queues moments on the device before sending
them, so a moment logged with no signal is kept rather than discarded. That
introduces a failure the previous fire-and-forget client did not have: the record
is created but the response is lost, and the next flush would send it again. A
partial unique index (`client_id != ''`, so the empty values on older rows do not
collide) turns the repeat into a `400` with
`data.client_id.code = "validation_not_unique"`, which the client treats as
"already recorded" and drops from its queue.

### `pairs`

A "connection". Two members is the 1:1 case; more than two is a group. The
collection kept its original name, because `pair_members` was a join table from
the start and groups therefore needed no data migration.

| Field | Type | Notes |
|---|---|---|
| `id` | string | |
| `name` | string | free text, `""` when unnamed |
| `created` | date | |

Creation is closed to clients — a `pairs` row only ever appears via
`POST /api/peard/pairs/accept`. Any member may set `name`
(`PATCH /api/collections/pairs/records/{id}`); the update rule is
`pair_members_via_pair.user ?= @request.auth.id`.

### `pair_members`

| Field | Type | Notes |
|---|---|---|
| `id` | string | |
| `pair` | string | relation → `pairs` |
| `user` | string | relation → `users` |
| `role` | `"owner"` \| `"member"` | open |
| `muted` | bool | the caller has silenced this connection's pushes |

`muted` is not writable through the collection API, and `pair_members` has no
update rule at all. That is deliberate: PocketBase rules cannot restrict *which*
fields an update touches, so any rule permissive enough to let a member set
`muted` would also let them rewrite their own `role` or repoint `pair` at a
connection they are not in. Muting goes through
`POST /api/peard/connections/mute`, which writes that one field and nothing else.

`expand=user` only resolves for the signed-in user: the `users` view rule is
`id = @request.auth.id`, so other members' records are not readable by the
client. Their display names come from `GET /api/peard/connections`, which
resolves them server-side.

A user may hold up to 20 memberships, and a connection up to 12 members. Both
limits are enforced by the invite and accept routes, which answer `400` with a
`message` explaining which was hit.

### `moment_kinds`

One custom moment, scoped to a connection, so every member draws it the same
way. Built-in kinds (`beer`, `loo`, `coffee`) have no row.

| Field | Type | Notes |
|---|---|---|
| `id` | string | |
| `pair` | string | relation → `pairs` |
| `slug` | string | max 40, matches `posts.event_kind` |
| `emoji` | string | max 16 |
| `label` | string | max 40 |
| `created_by` | string | relation → `users` |
| `created` | date | |
| `updated` | date | |

Unique index on `(pair, slug)`. Any member may list, view, create (with
`created_by` equal to themselves) and update a row; only the member who added it
may delete it. A row whose `slug` matches a built-in overrides it, so a
connection can re-label `loo` without ending up with two of them.

Slugs are derived client-side from the typed label: lower-cased, diacritics and
emoji stripped, words joined with `_`, truncated to 40 characters, falling back
to `moment` when nothing slug-safe remains.

### `reactions`

| Field | Type | Notes |
|---|---|---|
| `id` | string | |
| `post` | string | relation → `posts` |
| `user` | string | relation → `users` |
| `kind` | `"cheers"` \| `"plus_one"` \| `"heart"` | open |

Unique index on `(post, user, kind)`: creating a duplicate answers `400`, which
the client treats as "already reacted" rather than an error.

### `devices`

| Field | Type | Notes |
|---|---|---|
| `id` | string | |
| `user` | string | relation → `users` |
| `platform` | `"ios"` \| `"android"` | |
| `push_token` | string | lower-case hex APNs token, unique index |

### `users` (subset the client reads)

| Field | Type |
|---|---|
| `id` | string |
| `email` | string |
| `display_name` | string |

## Auth responses

`POST /api/peard/auth/apple`,
`POST /api/collections/users/auth-with-oauth2`,
`POST /api/collections/users/auth-with-password` all answer:

```json
{ "token": "<pb auth token>", "record": { "id": "...", "email": "...", "display_name": "..." } }
```

Apple sign-in request body:

```json
{ "identity_token": "<apple JWT>", "nonce": "<raw nonce>", "display_name": "Ada Lovelace" }
```

`nonce` is the raw value; the request sent to Apple used its lower-case hex
SHA-256. Google code exchange body:

```json
{ "provider": "google", "code": "...", "codeVerifier": "...", "redirectURL": "peard://auth/google" }
```

### Apple server-to-server notifications

`POST /api/peard/auth/apple/notifications` is **not called by the client**. It is
the URL configured as the App ID's *Server-to-Server Notification Endpoint*, and
Apple is the only caller:

```json
{ "payload": "<signed JWT>" }
```

The JWT is RS256, signed with the same keys as the identity token, and carries
`iss`, `aud` (the bundle id), `iat`, `jti` and `events`. Two differences from an
identity token drive the implementation:

- there is **no `exp`**, so freshness is bounded by `iat` — 24 h maximum age,
  5 min future skew — otherwise a captured notification would verify forever and
  could be replayed to sign somebody out at will;
- `events` is a **string containing JSON**, not a nested object, so the payload
  is doubly encoded. The server accepts an object too.

The decoded event is `{ "type", "sub", "email", "is_private_email", "event_time" }`,
where `is_private_email` may be a bool or the string `"true"`.

| Response | When |
|---|---|
| `200 {"status":"applied"}` | Verified, matched a user, action performed |
| `200 {"status":"acknowledged"}` | Verified; no action (unknown user, or a record-only event) |
| `200 {"status":"unparsable"}` | Verified as Apple's, but the `events` claim did not parse |
| `400` | No `payload` field |
| `401` | Signature, issuer, audience or freshness check failed |
| `500` | The action failed; Apple should retry |

Apple retries on any non-2xx, so a verified notification the server chooses not
to act on still answers 200 — only an unverifiable one is rejected. Actions are
idempotent, because a retry arrives as the same event.

| Event `type` | Effect |
|---|---|
| `email-disabled` / `email-enabled` | Recorded only. Pear'd sends no email — auth is OAuth-only and notifications go over APNs — and the relay address stays valid as the linking identity even when it no longer forwards. |
| `consent-revoked` | Auth tokens invalidated, widget tokens revoked, APNs devices deleted, `_externalAuths` Apple link removed. Account and moments kept. |
| `account-delete` | As `consent-revoked`. Also deletes the user record when `PEARD_APPLE_ERASE_ON_ACCOUNT_DELETE=true`, which cascades their posts out of every shared timeline — off by default for that reason. |

## Connection routes

`GET /api/peard/connections` lists every connection the caller belongs to,
oldest membership first:

```json
{
  "connections": [
    {
      "pair": "abc123def456ghi",
      "name": "Flatmates",
      "created": "2026-07-20 09:00:00.000Z",
      "role": "owner",
      "muted": false,
      "unread": 2,
      "last_seen_at": "2026-07-31 16:04:00.000Z",
      "member_count": 3,
      "is_group": true,
      "avatar": "photo_a1b2c3d4e5.jpg",
      "members": [
        { "user": "u1", "name": "Ada",   "role": "owner",  "is_you": true,  "avatar": "ada_f6g7h8i9j0.jpg" },
        { "user": "u2", "name": "Grace", "role": "member", "is_you": false, "avatar": "" },
        { "user": "u3", "name": "Alan",  "role": "member", "is_you": false, "avatar": "" }
      ]
    }
  ]
}
```

This route exists because the `users` view rule hides other members' records:
without it every unnamed connection would be titled "Partner" and a switcher
holding several of them would be unusable. Only the resolved display name is
returned — never the email — so learning who shares a connection with you does
not also hand out their address. `name` follows `display_name` → email local
part → `"Someone"`.

The client titles a connection with, in order: `name`, the other person's name
for a 1:1, `"Grace & Alan"` for a two-other group, then `"Grace +2"`. A connection
holding only you — reachable, since leaving removes a membership and nothing
removes the connection behind it — is titled `"Just you"`, and its second tally
row is labelled `"Someone"` rather than `"Partner"`, matching what the timeline
calls an author who is no longer a member.

### Avatars

Both `avatar` fields are **stored filenames, not URLs**, matching how
`posts.media` already travels: a URL would bake the host into a response the
device caches, and the device already knows its own base URL. An empty string
means nothing has been uploaded.

The client builds `/api/files/<collection>/<record>/<filename>?thumb=<size>`,
so the connection's own photo is under `pairs/<pair>` and a member's is under
`users/<user>`. Two thumb sizes exist — `128x128` for the rail and member rows,
`512x512` for the settings screen. Asking for any other size makes PocketBase
serve the original, which for a rail of twelve circles is megabytes of nothing.

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/api/peard/profile/avatar` | multipart `avatar` | `{ id, display_name, email, avatar }` |
| DELETE | `/api/peard/profile/avatar` | — | same, `avatar: ""` |
| POST | `/api/peard/connections/avatar` | multipart `pair`, `avatar` | `{ pair, avatar }` |
| DELETE | `/api/peard/connections/avatar?pair=` | — | `{ pair, avatar: "" }` |

Routes rather than collection writes because `users.UpdateRule` is
`id = @request.auth.id`, which is the *whole record*: a PATCH that can also carry
`email` or `emailVisibility` is a wider grant than "let me pick a picture", and
narrowing a rule to one field is not expressible. Any member may set a
connection's photo, matching rename — a connection's name and face are shared
property. Clearing is a DELETE rather than an empty POST, because PocketBase
deletes the previous file when the field is set to nothing, so an accidental
empty upload would silently erase a photo.

Accepts JPEG, PNG, WebP and HEIC up to 8 MB; the client downscales to 512 points
and re-encodes as JPEG first, so the limit is not normally reachable.

The two avatar file fields are deliberately **unprotected**, as `posts.media`
already is. PocketBase only enforces a collection's view rule on files when the
field is protected, and `users.ViewRule` is `id = @request.auth.id` — so a
protected avatar would be invisible to exactly the people who need to see it,
everybody else in the connection. Unprotected means the URL is the capability,
which is defensible only because PocketBase appends a ten-character random suffix
to every stored filename: the path cannot be derived from a record id. There is a
test asserting that, since the whole argument rests on it. The consequence to be
aware of is that somebody who leaves a connection keeps any avatar URL they
already had.

`POST /api/peard/connections/mute` with `{ "pair": "<id>", "muted": true }` →
`{ "ok": true, "muted": true }`. Per membership rather than per user: with 20
connections of up to 12 people each, the useful control is "this group is too
noisy", not "stop notifying me". A muted connection still delivers moments and
still appears in the widget — it just stops making a sound, and its reactions go
quiet too.

`POST /api/peard/connections/seen` with `{ "pair": "<id>" }` →
`{ "ok": true, "last_seen_at": "2026-07-31 16:04:00.000Z" }`. Marks the caller's
membership read up to now, which is what `unread` above counts from. `404` if you
are not a member of that connection.

The stamp is the server's clock, and a timestamp in the body is ignored. It is
compared against `posts.created`, which the server also writes, so honouring a
device's idea of "now" would let a phone running fast mark moments read before
they were posted — and one running slow leave them unread forever.

`unread` counts moments in that connection, authored by somebody other than the
caller, created after that stamp. With no stamp — you have never opened the
connection — the cut-off is the membership's own `created`, so joining a
five-year-old group does not hand you a badge of everything ever posted in it.
Your own moments never count: logging something is not news to the person who
logged it.

Muted connections still report `unread`; muting silences the alert, it does not
mean "stop telling me anything happened". The APNs badge is the one place muted
connections are excluded, because the badge accompanies an alert a muted
connection would not have produced.

`last_seen_at` is that same cut-off, sent so a client can show *which* moments
are new rather than only how many. It is always the effective value — a
never-opened connection reports its membership's `created`, not an empty string
— so the join-date fallback is applied in one place instead of being re-derived
on each client and getting subtly different.

The app freezes this value per connection for the life of a session rather than
reading it live. Opening a connection stamps it to now, so a divider drawn from
the current value would disappear before the user could navigate to the timeline
that shows it.

## Tally routes

`GET /api/peard/tallies?pair=<id>&day=<iso>&week=<iso>&month=<iso>`:

```json
{
  "pair": "abc123def456ghi",
  "mine":   { "day": 6, "week": 14, "month": 14, "all": 14 },
  "others": { "day": 0, "week": 2,  "month": 2,  "all": 2 },
  "kinds": [
    {
      "kind": "beer", "emoji": "🍺", "label": "Beer",
      "mine":   { "day": 2, "week": 4, "month": 4, "all": 4 },
      "others": { "day": 0, "week": 1, "month": 1, "all": 1 },
      "total": 5
    }
  ]
}
```

`mine` is the caller's own moments, `others` is everybody else's — the two rows
the home screen draws. Each window is counted independently, so a week straddling
a month boundary cannot inflate the month.

This replaced counting on the device. The client used to request every `event`
post of a connection (`perPage=500`, sorted `-created`) and count them locally on
every tap, which silently undercounted past 500 event posts — a group of twelve
reaches that in weeks — and moved up to 500 records to derive eight integers.

The three window boundaries are **supplied by the caller** as RFC 3339 instants,
because they are the device's: local midnight and a Monday-start week. A server
guessing its own would make a phone in Sydney disagree with a server in London
about what "today" means. When they are absent the server falls back to its own
local boundaries, so a client that does not send them still gets sensible numbers.

`kinds` is what the app's moment breakdown draws. Two things about it matter to a
renderer:

- **The per-kind rows can sum to less than `mine` + `others`.** A post saved with
  no `event_kind` counts towards its author's side totals but belongs to no kind.
  A share-of-total bar must therefore be drawn against the sum of the rows, not
  against the side totals, or the parts would never reach the whole.
- **`emoji` and `label` are always populated.** A kind with no `moment_kinds` row
  falls back to 🍐 and a humanised slug (`dog_walk` → `Dog walk`). That is a real
  case rather than a defensive one: removing a custom moment deliberately leaves
  past posts with their kind so past tallies are unaffected, so a slug outlives its
  row. Because the server always sends a label, a client must not expect to do the
  humanising itself.

`kinds` is omitted entirely by servers predating this route's per-kind support, so
a client should treat an empty list as "no breakdown available" rather than "no
moments".

`403` when the caller is not a member of `pair`.

## Profile routes

`GET /api/peard/profile` and `POST /api/peard/profile` with
`{ "display_name": "Ada" }` both answer:

```json
{ "id": "u1", "display_name": "Ada", "email": "ada@example.com" }
```

This is the only way to set the name other people see. `display_name` is what
`GET /api/peard/connections` resolves members to, and with none set it falls back
to the email's local part — so a group of four reads as a list of email prefixes.

It is a route rather than a `PATCH` against the `users` collection for the same
reason as muting: a rule permissive enough to admit `display_name` would also
admit `email`, `password` and `emailVisibility`. The value is trimmed, internal
whitespace runs are collapsed to single spaces, control characters are stripped,
and it is truncated to 80 **runes** — a byte truncation could split a multi-byte
character into invalid UTF-8. An empty value is a deliberate reset back to the
email fallback, not an error.

## Account routes

`GET /api/peard/export` → a JSON snapshot of the caller's own profile,
connections and authored moments. The app writes it to a file and hands it to the
share sheet.

`DELETE /api/peard/account` (no body) → `{ "ok": true }`. Deleting the `users`
record is the whole act: every relation pointing at a user — `pair_members`,
`posts`, `reactions`, `pair_invites`, `devices`, `widget_tokens` — was declared
`CascadeDelete: true`, and losing the last member of a connection deletes that
connection's own posts, reactions and moment kinds through the `pair_members`
delete hook. A connection that still has other members keeps its shared history;
only the deleted account's moments in it go.

The two together are the self-serve half of the privacy policy's promise: take a
copy, then leave, without asking anybody.

## Pairing routes

`POST /api/peard/pairs/invite` with an optional body:

```json
{ "pair": "abc123def456ghi" }
```

Omitting `pair` (or sending no body at all) mints an invite that creates a new
1:1 connection when accepted. Supplying `pair` mints one that adds the accepting
user to that existing connection, which is how a group grows; the caller must
already be a member, or the answer is `403`.

```json
{ "code": "AB12CD", "expires": "2026-08-04 21:30:15.250Z", "deep_link": "peard://pair/AB12CD", "pair": "abc123def456ghi" }
```

`pair` is echoed back only for a group invite, and is what the client uses to
word the share sheet as "Join my group" rather than "Pear up with me".

`POST /api/peard/pairs/accept` with `{ "code": "AB12CD" }` → `{ "pair": "<id>" }`,
which is either the newly created connection or the one the invite targeted.
Accepting your own invite, an expired one, or an invite into a connection you are
already in all answer `400`.

`POST /api/peard/pairs/leave` with an optional body:

```json
{ "pair": "abc123def456ghi", "delete_moments": false }
```

→ `{ "ok": true }`. Omitting `pair` is only unambiguous when the caller belongs
to exactly one connection; with more than one the answer is `400`. Leaving
deletes the membership, and deletes the connection itself once the last member
goes, cascading to its posts, reactions and moment kinds.

`delete_moments` is a real JSON boolean (a quoted `"true"` is rejected with
`400`) and defaults to `false`, so a client that has never heard of the field
keeps the original behaviour: the caller's moments stay in the shared timeline,
because they were part of everybody else's record of what happened too. Sent
`true`, the caller's own posts in *that connection* are deleted first, while the
membership still names them — scoped to one connection, unlike account deletion.

`POST /api/peard/pairs/remove` with `{ "pair": "<id>", "user": "<id>" }` →
`{ "ok": true }`. Takes somebody *else* out of a connection, and only the owner
may: `403` otherwise, `400` if `user` is the caller (leaving is a different act,
with a different authority and its own tidying up). The removed member's moments
stay in the shared timeline — deleting half a conversation because somebody left
is not what anybody asked for — and the client attributes a post by a former
member to `"Someone"` rather than "Partner", which would be wrong in a group.

Invites expire after 7 days and are swept to `status = "expired"` by a cron job
every 15 minutes.

Invite codes are 6 characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (no
visually ambiguous characters).

## Widget routes

`POST /api/peard/widget/token` → `{ "id": "<record id>", "token": "<hex>" }`.

`GET /api/peard/widget/feed?token=<token>[&pair=<id>]` (no PocketBase session):

```json
{
  "state": "ok",
  "partner": { "name": "Ada" },
  "connection": { "id": "abc123def456ghi", "name": "Flatmates", "member_count": 3, "is_group": true },
  "counts": { "beer": 2, "loo": 1 },
  "tallies": [
    { "kind": "beer", "emoji": "🍺", "count": 2, "label": "Beer" },
    { "kind": "tea",  "emoji": "🫖", "count": 1, "label": "Tea" }
  ],
  "moments": [
    { "kind": "beer",   "emoji": "🍺", "label": "Beer" },
    { "kind": "loo",    "emoji": "💩", "label": "Loo" },
    { "kind": "coffee", "emoji": "☕", "label": "Coffee" }
  ],
  "post": {
    "id": "...",
    "type": "event",
    "event_kind": "beer",
    "emoji": "🍺",
    "label": "Beer",
    "note": "cheers",
    "created": "2026-07-28 21:30:15.250Z",
    "media_url": "http://host/api/files/posts/<id>/<file>?thumb=512x512",
    "author": "Ada"
  }
}
```

`state` is `ok`, `empty` (in a connection, nobody else has posted) or
`unpaired`. `partner`, `connection`, `counts`, `tallies` and `post` are absent
when `state` is `unpaired`; `post` is absent when `state` is `empty`.

The widget has room for one connection. `pair` pins it to a particular one, which
is what a configured widget sends; a `pair` the caller is not a member of is
ignored rather than refused, so a widget left pointing at a group the user has
left falls back rather than failing to render. Without `pair` the server picks
whichever connection somebody else posted in most recently, falling back to the
newest membership when nobody else has posted anywhere. `connection` describes
whichever was chosen, so a group can be captioned as one rather than implying a
single partner. `partner.name` is whoever wrote `post` — the other member in a
1:1, the actual author in a group — and follows `display_name` → email local part
→ `"Partner"`.

`tallies` covers every moment kind anybody else logged in that connection today,
most frequent first, with `emoji` and `label` resolved server-side against the
connection's `moment_kinds` so the widget needs no catalogue of its own.
Unresolvable kinds come back as `🍐`. `counts` is the original beer/loo pair,
kept so an installed widget build that predates `tallies` keeps rendering.

`moments` is what the widget's own buttons may log: the built-ins followed by the
connection's published kinds, with a published kind replacing a built-in of the
same slug. It is absent on a server predating interactive buttons, and the client
falls back to the three built-ins.

"Today" is local midnight on the server, converted to UTC before comparison.

`GET /api/peard/widget/connections?token=<token>`:

```json
{
  "connections": [
    { "id": "abc123def456ghi", "title": "Flatmates", "member_count": 3, "is_group": true }
  ]
}
```

Deliberately thinner than `GET /api/peard/connections`: a configurable widget's
picker needs an id and something to call it, and no more. `title` follows the same
precedence the client uses — the connection's name, else who else is in it.

`POST /api/peard/widget/moment`:

```json
{ "token": "<token>", "pair": "abc123def456ghi", "kind": "beer", "client_id": "<uuid>" }
```

→ `{ "id": "<post id>", "pair": "<id>", "kind": "beer", "emoji": "🍺", "label": "Beer" }`

Logs a moment straight from a widget button. This is what makes the widget
interactive without sharing the Keychain with the extension — the alternative was
a keychain access group so it could read the PocketBase session token, a far wider
grant for a much smaller job. The widget token is already revocable and already in
the App Group container, and this route only ever creates an `event` post.

`pair` is optional and defaults to the same connection the feed would have chosen.
`kind` must be a built-in or a kind the connection has published, else `400` —
without that check this would be a route for writing arbitrary 40-character
strings into `event_kind`, which every other client would then draw as a pear.
`client_id` is honoured exactly as on a normal `posts` write, so a tap whose
response is lost cannot double-log.

## Widget authentication

Every `/api/peard/widget/*` route except `token` authenticates with the widget
token rather than a PocketBase session, because the extension cannot read the
Keychain. A missing, unknown, revoked or expired token answers `401`.

## Errors

Non-2xx responses carry:

```json
{ "status": 400, "message": "Failed to create record.", "data": { "email": { "code": "validation_not_unique", "message": "Value must be unique." } } }
```

The client shows `message` when present and falls back to the status code.
`401` clears the stored session and returns the app to sign-in.
