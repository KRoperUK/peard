# Pear'd 🍐

Moments and tallies shared with your favourite people — like a locket for photos,
a counter for the beers, and a nod for the loo.

A **connection** is a shared timeline. Two people is a pair; more than two is a
group. You can be in several at once (up to 20, each holding up to 12 people) and
switch between them from a rail of faces at the top of the home screen — pairs
are circles, groups are squircles, and anyone with no photo gets their initials
over a colour derived from their record id, so the same person is the same colour
on every screen. Four tabs sit underneath: Home for logging, Timeline for the
whole shared history, Tallies for the counts and the per-moment breakdown, and
Settings for the connection's photo, name, members and muting.

You can only see somebody's name or photo if you share a connection with them.
That is enforced by collection rules on the server, not by the app, and
`server/internal/access` holds the suite that proves it.

**Moments** are the one-tap things worth saying: `beer`, `loo` and `coffee` are
built in, and any connection can invent its own — pick from a recommended list or
type a label and choose an emoji. Tapping a moment sends it on its own after
**three seconds**; the window is there only so you can add a note, and typing one
holds the send until you tap it yourself. A moment logged with no signal is kept
on the device and sent when there is one, so a pub basement is not a reason to
lose it.

## Structure

```
peard/
├── server/       PocketBase used as a Go framework (extended)
│   └── Dockerfile         two-stage, CGO-free, non-root alpine image
├── ios/          Native SwiftUI app + WidgetKit extension
│   ├── project.yml        XcodeGen spec — the source of truth for the project
│   ├── Peard/             app target
│   ├── PearWidget/        widget extension target
│   ├── PeardTests/        app-target XCTest bundle
│   ├── PeardCore/         shared Swift package (models, API client, App Group)
│   └── Shared/            colour assets used by both targets
├── fastlane/     build, test and TestFlight lanes
├── docs/         wire contract between app and server
├── docker-compose.yml      the server stack (HTTP, proxy in front)
├── docker-compose.tls.yml  override: PocketBase owns 80/443 and its own cert
└── docker-compose.cloudflared.yml  override: no host port, cloudflared ingress
```

`ios/Peard.xcodeproj` is **generated** from `ios/project.yml` and is not
committed. Add or rename a source file and the next `make project` picks it up;
there is no file list to maintain and no `project.pbxproj` merge conflicts. The
flip side is that build settings changed in Xcode's editor are thrown away on
regenerate — they belong in `project.yml`.

## Quick start

### 1. Server

```bash
make server                    # cd server && go run . serve --http=127.0.0.1:8090
```

The first run auto-applies the Go migrations (pairs, posts, reactions,
timestamps, muting, etc.). To apply them without starting the server:
`make migrate`.

**Admin UI:** http://127.0.0.1:8090/_/ – create a superuser on first visit.

### 2. iOS app

```bash
brew install xcodegen                                # once
cp ios/Config.example.xcconfig ios/Config.xcconfig   # optional, for overrides
make project                                         # generate Peard.xcodeproj
make app                                             # build app + widget
make run                                             # build, install, launch on a simulator
```

Or open `ios/Peard.xcodeproj` in Xcode after `make project` and run the `Peard`
scheme. Requires Xcode 26 or newer and XcodeGen; the deployment target is
iOS 17. There is no CocoaPods and no Node.

### 3. Tests

```bash
make test          # PeardCore unit tests — fast, no simulator
make test-app      # app-target tests (quick-send flow, routing) on a simulator
make test-all      # both, plus go test ./...
make lint          # go vet, and check project.yml still generates
```

`PeardCore` builds for macOS as well as iOS so its suite runs under plain
`swift test`; nothing in it may import UIKit. The app-target bundle exists for
what cannot follow that rule — `HomeModel`'s countdown and `AppModel`'s routing
are `@MainActor` and import UIKit.

### 4. Fastlane

```bash
bundle install
bundle exec fastlane test            # PeardCore + server + app target
bundle exec fastlane build           # Debug simulator build
bundle exec fastlane release_build   # Release build
bundle exec fastlane beta            # archive + TestFlight
```

Every lane that touches Xcode regenerates the project first. `archive` and `beta`
need App Store Connect credentials in the environment and say exactly which ones
if they are missing:

| Variable | Purpose |
|---|---|
| `APP_STORE_CONNECT_API_KEY_ID` | API key id |
| `APP_STORE_CONNECT_API_ISSUER_ID` | Issuer id |
| `APP_STORE_CONNECT_API_KEY_CONTENT` | The `.p8` contents (or `…_KEY_PATH`) |
| `PEARD_BUILD_NUMBER` | Optional; CI sets it so each upload is unique |
| `PEARD_APP_STORE_APP_ID` | Optional; overrides the App Store Connect app id, `6795739297` |

`beta` uploads against that numeric app id rather than looking the app up by
bundle id, because the lookup needs an API key allowed to list every app on the
account. A key scoped to one app can upload perfectly well but cannot enumerate,
and the failure reads as "app not found" rather than as a permissions problem.

### 5. Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and every pull request,
in four jobs so a server-only change is not stuck behind Xcode:

- **Server** (Ubuntu) — `go build`, `go vet`, `go test`, and a `gofmt` gate.
- **Docker** (Ubuntu) — validate both compose files, build the image, then start
  it and wait for `/api/health`. A green `go build` does not prove the container
  serves, and migrations apply on start, so this is where a broken image surfaces
  rather than mid-deploy.
- **PeardCore** (macOS) — `swift test`, no simulator needed.
- **App** (macOS) — generate the project, build Debug *and* Release, then run the
  app-target tests. On failure the `.xcresult` bundle is uploaded as an artifact.

Neither macOS job pins an `Xcode_NN.app` path or names a simulator: both come and
go with the runner image, and hard-coding either turns an image update into a red
build for a reason that has nothing to do with the code. The simulator is chosen
from what `simctl` reports as available.

### Configuration

The server URL is baked into `Info.plist` at build time, and the two
configurations need different ones, so each has its own xcconfig:

| File | Sets | Committed |
|---|---|---|
| `ios/Config.debug.xcconfig` | `http://127.0.0.1:8090` | yes |
| `ios/Config.release.xcconfig` | `https://peard.kroper.uk` | yes |
| `ios/Config.example.xcconfig` | everything both share | yes |
| `ios/Config.xcconfig` | your overrides | no, git-ignored |
| `ios/Config.release.local.xcconfig` | Release-only overrides | no, git-ignored |

Copy the example to `ios/Config.xcconfig` and both configurations read it — but
where it sits in the include order differs, on purpose:

- **Debug** reads it last, so a LAN address for a physical device wins outright.
- **Release** reads it *before* pinning `peard.kroper.uk`, so settings like the
  Google client id still apply while the server host cannot be changed by
  accident. Your local file almost certainly says `127.0.0.1`, and shipping that
  to TestFlight is a build nobody can sign into, with nothing on screen to say
  why. To point an archive somewhere else deliberately — a staging host — put the
  host in `ios/Config.release.local.xcconfig`, which is read last of all.

| Setting | Debug | Release | Purpose |
|---|---|---|---|
| `PEARD_SERVER_SCHEME` | `http` | `https` | Server scheme |
| `PEARD_SERVER_HOST` | `127.0.0.1:8090` | `peard.kroper.uk` | Server host and port |
| `PEARD_GOOGLE_IOS_CLIENT_ID` | *(empty)* | *(empty)* | Google iOS OAuth client id |
| `PEARD_DEBUG_SUPERUSER_IDENTITY` | `admin@peard.app` | — | Debug fake-pair shortcut only |
| `PEARD_DEBUG_SUPERUSER_PASSWORD` | `Password123!` | — | Debug fake-pair shortcut only |

The Release defaults are tracked rather than left to the git-ignored file
because CI has no copy of it: an archive built on a runner would otherwise ship
pointing at `127.0.0.1`.

The URL is split into scheme and host because xcconfig treats `//` as the start
of a comment; `Info.plist` rejoins them. Use your LAN address for a physical
device — `127.0.0.1` only works in the simulator. Debug builds permit cleartext
HTTP to local addresses; Release builds do not, which is why the production host
must be HTTPS.

### Deployment

The production server is **https://peard.kroper.uk**, which is what a Release
build — and therefore every TestFlight build — talks to. Two supported shapes:
Docker (below) or the binary directly.

```bash
cd server && go build -o peard-server .
./peard-server serve peard.kroper.uk --https=0.0.0.0:443
```

`--https` makes PocketBase manage its own Let's Encrypt certificate, stored in
`pb_data`. That needs the DNS `A`/`AAAA` record for `peard.kroper.uk` pointing at
the host, and both **80** and **443** reachable — port 80 is where the ACME
challenge is answered, and it redirects to HTTPS afterwards. Migrations apply on
start, so a deploy is: build, replace the binary, restart.

The domain is a **positional** argument and it is not optional. PocketBase feeds
it to `autocert.HostWhitelist`; with only `--https=0.0.0.0:443` it falls back to
the address's host part and whitelists the literal string `0.0.0.0`, so Let's
Encrypt is never asked for the real domain and TLS never comes up.

`server/.env.example` lists the environment variables and their production
values. Nothing parses that file — the server reads the process environment — so
point systemd at it with `EnvironmentFile=` or export the values however the host
prefers. `PEARD_APNS_PRODUCTION=true` is the one that is easy to miss and silent
when wrong: TestFlight builds carry `aps-environment=production`, so their device
tokens only resolve on Apple's production APNs host.

### Docker, and Komodo repo-based stacks

`docker-compose.yml` at the repo root builds `server/Dockerfile` and is the whole
stack — one service, one volume. In [Komodo](https://komo.do), create a
**repo-based stack** pointing at this repository; it clones, writes the stack's
Environment to a `.env` beside the compose file, and runs
`docker compose up -d --build`. Every variable has a default, so a stack with an
empty Environment starts and serves.

```bash
docker compose up -d --build                 # HTTP on 8090, proxy in front
make docker-up                               # same thing
make docker-up-tls                           # PocketBase owns 80/443 itself
make docker-up-cloudflared                   # no host port; tunnel is the ingress
```

The base file serves plain HTTP on `${PEARD_HTTP_PORT:-8090}` and expects a
reverse proxy to terminate TLS — the right shape for most Komodo hosts, which
already run Traefik or Caddy, and it keeps the container off privileged ports.
Two overrides change that, and they are mutually exclusive.

#### Behind a cloudflared tunnel (no host port)

```bash
docker compose -f docker-compose.yml -f docker-compose.cloudflared.yml up -d --build
```

This publishes **nothing** on the host and joins the container to the network the
`cloudflared` container is already on, so the tunnel is the only way in. Then add
one public hostname to the tunnel — Cloudflare Zero Trust dashboard for a
token-run tunnel, `config.yml` for a locally configured one:

```
peard.kroper.uk  ->  HTTP  ->  peard-server:8090
```

HTTP on the origin leg is correct: Cloudflare terminates TLS at its edge, and the
hop from `cloudflared` to the container never leaves Docker's network. The app
still sees `https://peard.kroper.uk`, which is what a Release build requires.

`PEARD_CLOUDFLARED_NETWORK` names the network (default
`cloudflared_cloudflared`); it is declared `external`, so a wrong name fails at
`up` rather than creating an empty network with no tunnel on it — which would
otherwise pass its health check and be unreachable. Find the real name with:

```bash
docker inspect <cloudflared-container> \
  --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}'
```

Not publishing a port is the point rather than tidiness: a mapped port is a
second, unauthenticated ingress that bypasses Cloudflare — including for `/_/`,
the PocketBase dashboard. Outbound still works through the network's gateway,
which the server needs for Apple's JWKS, APNs and nothing else.

#### PocketBase manages its own certificate

```bash
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d --build
```

The override replaces the port mapping outright (`ports: !override`, needs
Compose 2.24+), passes `PEARD_TLS_DOMAIN` as the positional argument, and grants
`NET_BIND_SERVICE` so uid 1000 can bind 80 and 443 — narrower than the usual fix
of running as root. Do not combine it with a proxy that already owns those ports,
and do not combine it with the cloudflared override: the ACME challenge is
answered on port 80, which that override no longer publishes. Behind a *proxied*
Cloudflare DNS record it cannot work either, since Cloudflare intercepts 80.

In Komodo, list both paths in the stack's *Compose file paths*.

Variables are in `server/.env.example`, including the five that only the compose
files read (`PEARD_HTTP_PORT`, `PEARD_CLOUDFLARED_NETWORK`, `PEARD_TLS_DOMAIN`,
`TZ`, `PEARD_PB_ENCRYPTION_KEY`). Two are worth knowing before the first deploy:

**The APNs key travels as content, not a path.** A `.p8` is git-ignored, so a
repo-based stack cannot carry the file, and bind-mounting a host secret defeats
the point of deploying from the repo. `PEARD_APNS_KEY_CONTENT` accepts the PEM
verbatim, the PEM with literal `\n`, or base64 of it. A compose `.env` cannot
hold a multi-line value, so base64 is the form to use there:

```bash
base64 < AuthKey_XXXXXXXXXX.p8 | tr -d '\n'
```

**`pb_data` is a named volume.** It holds the SQLite databases, uploaded media,
and the Let's Encrypt certificate if TLS is managed here — the only state that
matters, and the only thing to back up. A fresh named volume inherits uid 1000
from the image; a *bind* mount does not, so a host directory has to be
`chown 1000:1000`'d by hand or the server cannot write.

The image is two-stage: `CGO_ENABLED=0` (PocketBase's SQLite driver is pure Go)
into `alpine`, ~50 MB, running as a non-root user. `ca-certificates` is required
rather than tidy — Apple's JWKS, APNs and Let's Encrypt are all outbound TLS.

### Debug shortcuts

Debug builds only (compiled out of Release entirely):

- **🔧 Login Test User** — password sign-in as `test@peard.local`.
- **Type `AAAAAA`** on the pairing screen — creates a pair with a seeded test
  partner and two seeded tally posts, so one device is enough.
- **Type `BBBBBB`** — creates a named three-person group ("Flatmates", with Ari
  and Bo) carrying a published custom moment, so groups, the connection switcher
  and the shared catalogue can be checked from one device.
- The reachability of `GET /api/health` is logged at launch under the
  `com.peard.app` subsystem.

## Wire contract

`docs/wire-contract.md` is the canonical description of the JSON exchanged
between app and server. It replaces the former `shared/types.ts`, which was
**deleted** when the React Native client was retired — the Swift models in
`ios/PeardCore/Sources/PeardCore/Models.swift` are now the only client mirror of
the contract, and their round-trip behaviour is covered by tests.

## Privacy consent

Nothing reaches the network until the privacy policy has been agreed to. The gate
is a phase of its own (`AppModel.Phase.consent`) that `bootstrap()` returns from
*before* loading the session, starting the send queue or probing health, and that
`handle(url:)` repeats — a `peard://pair/CODE` link is the one route into the app
that skips launch routing, and the pairing screen's first act is to redeem the
code against the server.

It sits ahead of the sign-in screen rather than on it: Apple, Google and
email/password all send an identifier off the device before there is an account
to attach it to, so a checkbox beside the buttons would already be too late.

The answer is stored per installation in the App Group container
(`SharedStore.privacyConsent`) as the accepted policy *version*, not a boolean —
`PrivacyConsent.currentVersion` tracks the "Last updated" date rendered by
`/privacy`, so changing the policy puts the gate back in front of everyone on
their next launch. It deliberately survives sign-out.

## Auth providers

### Sign in with Apple (native)

The app calls the native Apple dialog (`AuthenticationServices`) and POSTs the
identity token to `POST /api/peard/auth/apple`. The server verifies it against
Apple's JWKS, creates or links the user by verified email, and returns a
PocketBase auth token.

- Required env: `PEARD_APPLE_AUDIENCE` (default `com.peard.app` – your iOS bundle id).
- The `_externalAuths` collection is kept in sync so PB's built-in
  OAuth2/OIDC flows recognise the link.

#### Server-to-server notifications

Apple posts a signed JWT to the URL set as the App ID's **Server-to-Server
Notification Endpoint** when a user changes mail forwarding, revokes the app's
access, or deletes their Apple Account. Put this in that field:

```
https://peard.kroper.uk/api/peard/auth/apple/notifications
```

The field takes one absolute `https` URL per app group and requires TLS 1.2+,
which PocketBase's own Let's Encrypt certificate satisfies. It is safe to set
before there are users; it can be changed or cleared later.

What each event does is in
[`docs/wire-contract.md`](docs/wire-contract.md#apple-server-to-server-notifications).
The short version: mail-forwarding changes are recorded and no more, because this
server sends no email at all; `consent-revoked` ends every session — PB auth
tokens, widget tokens, APNs devices and the Apple link; `account-delete` does the
same and *keeps* the account unless `PEARD_APPLE_ERASE_ON_ACCOUNT_DELETE=true`.

That default is deliberate. `posts.author` is `CascadeDelete`, so deleting a user
also erases their moments from the shared timeline of every connection they were
in — history the other members can see and did not ask to lose. Which way that
should go is a product decision about other people's data, so it is a switch
rather than a webhook's choice.

Verification is deliberately stricter than the identity token's in one respect:
these notifications carry **no `exp` claim**, so a captured one would verify
forever. Freshness is bounded by `iat` instead (24 h, with 5 min of future skew),
which is well outside Apple's retry window but closes the replay hole.

### Sign in with Google (OAuth2 code + PKCE)

The app runs a standard PKCE flow (`ASWebAuthenticationSession`) and calls
PocketBase's `auth-with-oauth2`. PocketBase links by verified email.

- Create a **Google iOS OAuth client** (bundle `com.peard.app`) in the Google
  Cloud Console, with `peard://auth/google` as an allowed redirect.
- Configure the client id/secret on the `users` auth collection in the PB
  Dashboard (*Collections > users > Options > OAuth2 > Google*).
- Set `PEARD_GOOGLE_IOS_CLIENT_ID` in `ios/Config.xcconfig`.

## WidgetKit

The home-screen widget shows the latest moment somebody else shared and today's
tallies, and has **buttons that log a moment without opening the app** (App
Intents, iOS 17+). It is **configurable**: long-press → Edit Widget to pin it to
one connection, or leave it on Automatic and the server picks whichever is
liveliest.

- Authentication is a revocable widget token in the App Group container
  (`group.com.peard.app`), written after sign-in through `PeardCore`'s
  `SharedStore` (which replaced the `PearShared` Expo native module).
- The buttons post to `POST /api/peard/widget/moment` with that token, **not**
  the Keychain session — the extension cannot read the Keychain, and a keychain
  access group would be a much wider grant than "let the widget log a beer".
- A widget button may only log a built-in moment or one the connection has
  published, and carries a client id so a lost response cannot double-log.
- Timelines refresh every ~15 min, on every new post, and after every button tap
  (best-effort, subject to the system's reload budget).

## Push notifications (APNs)

Set the `PEARD_APNS_*` env vars to enable:
- A visible alert + silent background nudge on new posts.
- A visible alert on reactions.

Notifications are **grouped per connection** with a `thread-id`, so twelve people
tapping coffee produce one expandable stack rather than twelve banners, and
collapsed per moment kind so repeats update one notification in place while
different moments stay separate. The badge counts what other people have posted
across your connections in the last day. A muted connection is skipped entirely,
reactions included.

The app registers its APNs token in the `devices` collection after notification
authorization is granted. Without APNs the app still works — it just won't
receive live pushes.

## Custom API routes

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/peard/auth/apple` | none | Verify Apple identity token, return PB token |
| POST | `/api/peard/auth/apple/notifications` | Apple JWT | Apple's server-to-server notifications (not called by the app) |
| GET  | `/api/peard/connections` | user | Your connections, with members' display names and mute state |
| POST | `/api/peard/connections/mute` | user | Silence one connection's notifications |
| POST | `/api/peard/connections/seen` | member | Mark one connection read up to now |
| GET  | `/api/peard/tallies?pair=` | user | Per-member moment counts for day/week/month/all time |
| GET  | `/api/peard/profile` | user | Your own record |
| POST | `/api/peard/profile` | user | Set the name other members see |
| POST | `/api/peard/profile/avatar` | user | Set your profile photo (multipart) |
| DELETE | `/api/peard/profile/avatar` | user | Remove your profile photo |
| POST | `/api/peard/connections/avatar` | member | Set a connection's photo (multipart) |
| DELETE | `/api/peard/connections/avatar?pair=` | member | Remove a connection's photo |
| POST | `/api/peard/pairs/invite` | user | Generate a 6-char invite code; optional `{"pair":"X"}` invites into an existing connection |
| POST | `/api/peard/pairs/accept` | user | Accept an invite code (body `{"code":"X"}`) |
| POST | `/api/peard/pairs/leave` | user | Leave a connection; optional `{"pair":"X"}`, required when you're in more than one, plus optional `{"delete_moments":true}` to take your own moments out of it on the way |
| POST | `/api/peard/pairs/remove` | owner | Remove somebody else from a connection |
| POST | `/api/peard/contacts/match` | user | Which of the supplied contact hashes belong to discoverable accounts |
| GET  | `/api/peard/export` | user | JSON snapshot of your profile, connections and moments |
| DELETE | `/api/peard/account` | user | Delete your account and everything that cascades from it |
| GET  | `/api/peard/widget/feed?token=` | widget | Latest moment + today's tallies; optional `&pair=` pins a connection |
| GET  | `/api/peard/widget/connections?token=` | widget | Choices for the configurable widget's picker |
| POST | `/api/peard/widget/moment` | widget | Log a moment from a widget button |
| POST | `/api/peard/widget/token` | user | Issue a widget token |

Custom moments are plain collection access rather than a custom route: the app
lists and creates `moment_kinds` rows scoped to a connection.

`GET /api/peard/tallies` replaced counting on the device, which fetched up to 500
event posts per tap and silently undercounted beyond that. The window boundaries
travel with the request because they are the device's — local midnight and a
Monday-start week — so a phone abroad and the server cannot disagree about what
"today" means.

## Android

Pear'd is **iOS-only** and an Android client is **deferred**. Now that the client
is native SwiftUI, an Android client would require a **separate native
implementation** rather than a shared React Native codebase.

The server is unaffected: PocketBase, its Google OAuth flow, and its collection
API serve an Android client unchanged, and FCM would replace APNs for Android
delivery. Apple sign-in on Android would need Apple's web-service configuration,
or can be omitted.

## Roadmap

- [x] Groups — `pair_members` was already many-to-many; invites can now target an
      existing connection, and the home screen switches between them
- [x] Members' display names, via `GET /api/peard/connections` rather than a
      `users` view-rule change (the rule stays `id = @request.auth.id`, so no
      email is ever exposed)
- [x] Interactive widget buttons (iOS 17+ App Intents), and a configurable widget
- [x] Per-connection notification muting, now that a user can be in 20 of them
- [x] Server-side tallies — the device no longer fetches 500 posts to count them
- [x] Offline send queue, so a moment logged with no signal is not lost
- [x] The whole shared timeline, paginated, rather than the latest four moments
- [x] Profile and connection photos, with a rail of faces instead of a menu, and
      a tab bar so the timeline and the tallies each get a screenful
- [x] Cross-connection access control, proven rather than assumed — see
      `server/internal/access`, which found that a memberless connection was
      world-readable
- [x] Delete a connection when its last member leaves, rather than leaving it
      orphaned with everybody's moments still in it — enforced at the model
      layer in `server/internal/pairs/lifecycle.go`, because a membership row
      disappears through four different doors and `/pairs/leave` is only one
- [x] Find friends from your contacts, without a contact ever arriving in the
      clear, and a discoverability switch that is off by default
- [x] Quick-send from an iMessage thread, without leaving the conversation
- [x] Export your own data, delete your own account, and delete your own moments
      from a connection when you leave it — the privacy policy's promises made
      self-serve rather than "email us and we'll action it within 30 days"
- [x] Agree to the privacy policy before anything leaves the device — a phase
      ahead of sign-in, versioned so a changed policy asks again
- [ ] Read state, so the push badge can mean "unread" exactly rather than
      "somebody posted in the last day" — which is what it means today, so it
      reads 3 when you have seen all three and 0 when you have seen none
- [ ] Live Activity for "instant photo drop" moments (ActivityKit push-to-update)
- [ ] Android widget (Jetpack Glance) — blocked on the Android client decision above
- [ ] Media storage (S3 compatible via PB filesystem settings)

## Licence

MIT — see [LICENSE](LICENSE). The repository had no licence of its own until now:
the file that used to sit under `app/` was Expo's, from the `create-expo-app`
template, and went with the React Native client.
