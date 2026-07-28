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
but always emits milliseconds. `created` and `updated` are `autodate` fields
added by `migrations/1785196800_peard_timestamps.go`; records written before
that migration carry an empty string, which the client decodes as
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
| `event_kind` | string | free text, max 40; catalogue is `beer`, `loo`, `coffee` |
| `note` | string | max 280, `""` when unset |
| `media` | string | filename, `""` when unset |
| `created` | date | |
| `updated` | date | |

Thumbnail URL: `GET /api/files/posts/{id}/{media}?thumb=512x512`.

### `pair_members`

| Field | Type | Notes |
|---|---|---|
| `id` | string | |
| `pair` | string | relation → `pairs` |
| `user` | string | relation → `users` |
| `role` | `"owner"` \| `"member"` | open |

`expand=user` only resolves for the signed-in user: the `users` view rule is
`id = @request.auth.id`, so the partner's record is not readable by the client.
The partner's display name therefore comes from the widget feed (below).

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

## Pairing routes

`POST /api/peard/pairs/invite`:

```json
{ "code": "AB12CD", "expires": "2026-08-04 21:30:15.250Z", "deep_link": "peard://pair/AB12CD" }
```

`POST /api/peard/pairs/accept` with `{ "code": "AB12CD" }` → `{ "pair": "<id>" }`.

`POST /api/peard/pairs/leave` → `{ "ok": true }`.

Invite codes are 6 characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (no
visually ambiguous characters).

## Widget routes

`POST /api/peard/widget/token` → `{ "id": "<record id>", "token": "<hex>" }`.

`GET /api/peard/widget/feed?token=<token>` (no PocketBase session):

```json
{
  "state": "ok",
  "partner": { "name": "Ada" },
  "counts": { "beer": 2, "loo": 1 },
  "post": {
    "id": "...",
    "type": "event",
    "event_kind": "beer",
    "note": "cheers",
    "created": "2026-07-28 21:30:15.250Z",
    "media_url": "http://host/api/files/posts/<id>/<file>?thumb=512x512",
    "author": "Ada"
  }
}
```

`state` is `ok`, `empty` (paired, partner has posted nothing) or `unpaired`.
`partner`, `counts` and `post` are absent when `state` is `unpaired`; `post` is
absent when `state` is `empty`. `counts` covers the partner's tallies for the
current day only. `partner.name` follows `display_name` → email local part →
`"Partner"`.

## Errors

Non-2xx responses carry:

```json
{ "status": 400, "message": "Failed to create record.", "data": { "email": { "code": "validation_not_unique", "message": "Value must be unique." } } }
```

The client shows `message` when present and falls back to the status code.
`401` clears the stored session and returns the app to sign-in.
