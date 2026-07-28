# Pear'd 🍐

Moments and tallies shared with your favourite person — like a locket for photos,
a counter for the beers, and a nod for the loo.

## Structure

```
peard/
├── server/       PocketBase used as a Go framework (extended)
├── ios/          Native SwiftUI app + WidgetKit extension
│   ├── Peard.xcodeproj    hand-maintained, no generator
│   ├── Peard/             app target
│   ├── PearWidget/        widget extension target
│   ├── PeardCore/         shared Swift package (models, API client, App Group)
│   └── Shared/            colour assets used by both targets
└── docs/         wire contract between app and server
```

## Quick start

### 1. Server

```bash
make server                    # cd server && go run . serve --http=127.0.0.1:8090
```

The first run auto-applies the Go migrations (pairs, posts, reactions,
timestamps, etc.). To apply them without starting the server: `make migrate`.

**Admin UI:** http://127.0.0.1:8090/_/ – create a superuser on first visit.

### 2. iOS app

```bash
cp ios/Config.example.xcconfig ios/Config.xcconfig   # optional, for overrides
make app                                             # build app + widget
make run                                             # build, install, launch on a simulator
make test                                            # PeardCore unit tests
```

Or open `ios/Peard.xcodeproj` in Xcode and run the `Peard` scheme. Requires
Xcode 26 or newer; the deployment target is iOS 17. There is no CocoaPods, no
Node, and no prebuild step — the project file is committed and edited by hand.

### Configuration

`ios/Config.example.xcconfig` is the project's base configuration and holds the
defaults. Copy it to `ios/Config.xcconfig` (git-ignored) to override them; the
example file pulls the copy in with `#include?` when it exists.

| Setting | Default | Purpose |
|---|---|---|
| `PEARD_SERVER_SCHEME` | `http` | Server scheme |
| `PEARD_SERVER_HOST` | `127.0.0.1:8090` | Server host and port |
| `PEARD_GOOGLE_IOS_CLIENT_ID` | *(empty)* | Google iOS OAuth client id |
| `PEARD_DEBUG_SUPERUSER_IDENTITY` | `admin@peard.app` | Debug fake-pair shortcut only |
| `PEARD_DEBUG_SUPERUSER_PASSWORD` | `Password123!` | Debug fake-pair shortcut only |

The URL is split into scheme and host because xcconfig treats `//` as the start
of a comment; `Info.plist` rejoins them. Use your LAN address for a physical
device — `127.0.0.1` only works in the simulator. Debug builds permit cleartext
HTTP to local addresses; Release builds do not.

### Debug shortcuts

Debug builds only (compiled out of Release entirely):

- **🔧 Login Test User** — password sign-in as `test@peard.local`.
- **Type `AAAAAA`** on the pairing screen — creates a pair with a seeded test
  partner and two seeded tally posts, so one device is enough.
- The reachability of `GET /api/health` is logged at launch under the
  `com.peard.app` subsystem.

## Wire contract

`docs/wire-contract.md` is the canonical description of the JSON exchanged
between app and server. It replaces the former `shared/types.ts`, which was
**deleted** when the React Native client was retired — the Swift models in
`ios/PeardCore/Sources/PeardCore/Models.swift` are now the only client mirror of
the contract, and their round-trip behaviour is covered by tests.

## Auth providers

### Sign in with Apple (native)

The app calls the native Apple dialog (`AuthenticationServices`) and POSTs the
identity token to `POST /api/peard/auth/apple`. The server verifies it against
Apple's JWKS, creates or links the user by verified email, and returns a
PocketBase auth token.

- Required env: `PEARD_APPLE_AUDIENCE` (default `com.peard.app` – your iOS bundle id).
- The `_externalAuths` collection is kept in sync so PB's built-in
  OAuth2/OIDC flows recognise the link.

### Sign in with Google (OAuth2 code + PKCE)

The app runs a standard PKCE flow (`ASWebAuthenticationSession`) and calls
PocketBase's `auth-with-oauth2`. PocketBase links by verified email.

- Create a **Google iOS OAuth client** (bundle `com.peard.app`) in the Google
  Cloud Console, with `peard://auth/google` as an allowed redirect.
- Configure the client id/secret on the `users` auth collection in the PB
  Dashboard (*Collections > users > Options > OAuth2 > Google*).
- Set `PEARD_GOOGLE_IOS_CLIENT_ID` in `ios/Config.xcconfig`.

## WidgetKit

The home-screen widget fetches your partner's latest photo/tally via
`GET /api/peard/widget/feed` using a revocable widget token stored in the App
Group container (`group.com.peard.app`).

- After sign-in the app issues a token and writes it to the App Group through
  `PeardCore`'s `SharedStore` (which replaced the `PearShared` Expo native
  module), then calls `WidgetCenter.reloadAllTimelines()`.
- Widget timelines refresh every ~15 min plus on every new post (best-effort,
  subject to the system's reload budget).

## Push notifications (APNs)

Set the `PEARD_APNS_*` env vars to enable:
- A visible alert + silent background nudge on new posts.
- A visible alert on reactions.

The app registers its APNs token in the `devices` collection after notification
authorization is granted. Without APNs the app still works — it just won't
receive live pushes.

## Custom API routes

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/peard/auth/apple` | none | Verify Apple identity token, return PB token |
| POST | `/api/peard/pairs/invite` | user | Generate a 6-char invite code |
| POST | `/api/peard/pairs/accept` | user | Accept an invite code (body `{"code":"X"}`) |
| POST | `/api/peard/pairs/leave` | user | Leave the current pair |
| GET  | `/api/peard/widget/feed?token=` | widget | Partner's latest post + tallies |
| POST | `/api/peard/widget/token` | user | Issue a widget token |

## Android

Pear'd is **iOS-only** and an Android client is **deferred**. Now that the client
is native SwiftUI, an Android client would require a **separate native
implementation** rather than a shared React Native codebase.

The server is unaffected: PocketBase, its Google OAuth flow, and its collection
API serve an Android client unchanged, and FCM would replace APNs for Android
delivery. Apple sign-in on Android would need Apple's web-service configuration,
or can be omitted.

## Roadmap

- [ ] Let pair members read each other's `users` record, so the partner's name
      does not depend on the widget feed
- [ ] Live Activity for "instant photo drop" moments (ActivityKit push-to-update)
- [ ] Interactive widget buttons (iOS 17+ App Intents)
- [ ] Android widget (Jetpack Glance) — blocked on the Android client decision above
- [ ] Groups (the `pair_members` join table is already many-to-many)
- [ ] Media storage (S3 compatible via PB filesystem settings)
