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
      "member_count": 3,
      "is_group": true,
      "members": [
        { "user": "u1", "name": "Ada",   "role": "owner",  "is_you": true },
        { "user": "u2", "name": "Grace", "role": "member", "is_you": false },
        { "user": "u3", "name": "Alan",  "role": "member", "is_you": false }
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
for a 1:1, `"Grace & Alan"` for a two-other group, then `"Grace +2"`.

`POST /api/peard/connections/mute` with `{ "pair": "<id>", "muted": true }` →
`{ "ok": true, "muted": true }`. Per membership rather than per user: with 20
connections of up to 12 people each, the useful control is "this group is too
noisy", not "stop notifying me". A muted connection still delivers moments and
still appears in the widget — it just stops making a sound, and its reactions go
quiet too.

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
{ "pair": "abc123def456ghi" }
```

→ `{ "ok": true }`. Omitting `pair` is only unambiguous when the caller belongs
to exactly one connection; with more than one the answer is `400`. Leaving
deletes the membership, and deletes the connection itself once the last member
goes, cascading to its posts, reactions and moment kinds.

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
