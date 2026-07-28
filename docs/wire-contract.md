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
| `created` | date | |
| `updated` | date | |

Thumbnail URL: `GET /api/files/posts/{id}/{media}?thumb=512x512`.

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

Invites expire after 7 days and are swept to `status = "expired"` by a cron job
every 15 minutes.

Invite codes are 6 characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (no
visually ambiguous characters).

## Widget routes

`POST /api/peard/widget/token` → `{ "id": "<record id>", "token": "<hex>" }`.

`GET /api/peard/widget/feed?token=<token>` (no PocketBase session):

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

The widget has room for one connection, so the server picks whichever one
somebody else posted in most recently, falling back to the newest membership when
nobody else has posted anywhere. `connection` describes it, so a group can be
captioned as one rather than implying a single partner. `partner.name` is
whoever wrote `post` — the other member in a 1:1, the actual author in a group —
and follows `display_name` → email local part → `"Partner"`.

`tallies` covers every moment kind anybody else logged in that connection today,
most frequent first, with `emoji` and `label` resolved server-side against the
connection's `moment_kinds` so the widget needs no catalogue of its own.
Unresolvable kinds come back as `🍐`. `counts` is the original beer/loo pair,
kept so an installed widget build that predates `tallies` keeps rendering.

"Today" is local midnight on the server, converted to UTC before comparison.

## Errors

Non-2xx responses carry:

```json
{ "status": 400, "message": "Failed to create record.", "data": { "email": { "code": "validation_not_unique", "message": "Value must be unique." } } }
```

The client shows `message` when present and falls back to the status code.
`401` clears the stored session and returns the app to sign-in.
