# Design Document

## Overview

Peard_App replaces the Expo (React Native) client with a hand-maintained native
SwiftUI project at `ios/`. Peard_Server is untouched: the same PocketBase
collection REST API and the same `/api/peard/*` routes.

Three first-party build products:

| Product | Kind | Location |
|---|---|---|
| `Peard` | SwiftUI iOS app | `ios/Peard.xcodeproj` target `Peard` |
| `PearWidgetExtension` | WidgetKit extension | `ios/Peard.xcodeproj` target `PearWidgetExtension` |
| `PeardCore` | Shared Swift library | `ios/PeardCore` local Swift package |

`PeardCore` is a local Swift package rather than a fourth Xcode target. That
keeps Requirement 1.2's three-target rule intact, satisfies Requirement 1.4
(SPM + system frameworks only), and gives the Requirement 24 test suite a home
that runs with `swift test` — no simulator, no Xcode test target. Everything
worth unit-testing (models, date coding, filter escaping, tally periods,
elapsed-time labels) therefore lives in `PeardCore`, not in the app target.

```
ios/
├── Peard.xcodeproj/project.pbxproj      committed, hand-edited, no generator
├── Config.example.xcconfig              committed
├── Config.xcconfig                      git-ignored, developer-local
├── PeardCore/
│   ├── Package.swift
│   ├── Sources/PeardCore/               models, APIClient, SharedStore, formatting
│   └── Tests/PeardCoreTests/
├── Peard/                               app target sources + resources
└── PearWidget/                          widget target sources
```

## Architecture

```
                 ┌───────────────────────── Peard (app target) ─────────────────┐
                 │  PeardApp ─ AppModel(Pair_Phase) ─ DeepLinkRouter            │
                 │      │                                                       │
                 │      ├── AuthCoordinator      (AuthenticationServices)        │
                 │      ├── PairCoordinator                                     │
                 │      ├── HomeModel            (timeline/tallies/photo/react)  │
                 │      ├── PushCoordinator      (UserNotifications + APNs)      │
                 │      ├── WidgetSync                                           │
                 │      └── KeychainSessionStore (Security)                      │
                 └───────────────┬──────────────────────────────────────────────┘
                                 │ links
        ┌────────────────────────▼─────────────────────────┐
        │ PeardCore                                        │
        │  Domain models · PeardDate · APIClient ·          │
        │  FilterValue escaping · SharedStore(App Group) ·  │
        │  TallyPeriods · ElapsedTime · EventKindCatalogue  │
        └────────────────────────▲─────────────────────────┘
                                 │ links
                 ┌───────────────┴──── PearWidgetExtension ─────────────────────┐
                 │  PearWidget · Provider(TimelineProvider) · entry views        │
                 └──────────────────────────────────────────────────────────────┘
```

`Peard_Core` is the only place that knows the wire format. The widget decodes
`WidgetFeed` with the same type the app uses (Requirement 17.13).

## Components and Interfaces

### PeardCore — Domain models (R4)

```swift
public struct Post: Codable, Identifiable, Hashable {
    public let id, pair, author: String
    public let type: PostType            // .photo | .event | .unknown(String)
    public let eventKind: EventKind?      // CodingKeys map snake_case
    public let note, media: String?
    public let created: Date             // PeardDate strategy
}
public struct WidgetFeed: Codable, Hashable          // state/partner/counts/post
public struct PairInvite: Codable, Hashable          // code/expires/deep_link
public struct PairMember: Codable, Hashable          // pair/user/role
public struct Reaction: Codable, Hashable            // post/user/kind
```

Open enums carry unknown values instead of failing to decode (R4.7). Each is a
`RawRepresentable`-style enum with an `unknown(String)` case whose `encode(to:)`
writes the preserved string back, which is what makes the R4.8 round-trip
property hold for values the client has never seen:

```swift
public enum PostType: Codable, Hashable { case photo, event, unknown(String) }
public enum MemberRole: Codable, Hashable { case owner, member, unknown(String) }
public enum ReactionKind: Codable, Hashable { case cheers, plusOne, heart, unknown(String) }
public enum FeedState: Codable, Hashable { case ok, empty, unpaired, unknown(String) }
public struct EventKind: Codable, Hashable { public let rawValue: String }
```

`EventKind` stays a string wrapper (the server column is free-text `event_kind`,
max 40) with a catalogue of the three known kinds (R4.6):

```swift
public enum EventKindCatalogue {
    public static let all: [EventKindDescriptor] = [beer 🍺 "Beer", loo 💩 "Loo", coffee ☕ "Coffee"]
    public static func emoji(for: EventKind?) -> String   // 🍐 fallback (R11.4)
}
```

`PeardDate` implements the PocketBase format `yyyy-MM-dd HH:mm:ss.SSS'Z'` in UTC
with `en_US_POSIX`, exposed as `JSONDecoder.dateDecodingStrategy` /
`encodingStrategy` factories plus standalone `parse`/`format` for R4.10. The
parser also accepts the no-milliseconds variant the server emits for some
fields, but always *formats* with milliseconds so the round-trip is stable.

### PeardCore — APIClient (R5)

```swift
public protocol AuthTokenProviding: AnyObject, Sendable { var authToken: String? { get } }

public actor APIClient {
    public init(baseURL: URL, tokenProvider: AuthTokenProviding?, session: URLSession = .peard)
    public func list<T: Decodable>(_ collection: String, filter: String?, sort: String?,
                                  perPage: Int, expand: String?) async throws -> [T]
    public func first<T: Decodable>(_ collection: String, filter: String?) async throws -> T?
    public func create<T: Decodable>(_ collection: String, json: [String: Any]) async throws -> T
    public func createMultipart<T: Decodable>(_ collection: String,
                                              fields: [String: String], file: MultipartFile) async throws -> T
    public func delete(_ collection: String, id: String) async throws
    public func post<T: Decodable>(path: String, json: [String: Any]?) async throws -> T
    public func raw(path: String, query: [String: String]) async throws -> Data
}
```

- `Authorization` header on every request when a token exists (R5.1).
- `first` == `perPage: 1`, `sort: "-created"`, returns `items.first` (R5.3).
- 30 s `timeoutIntervalForRequest` on a dedicated `URLSession` config (R5.9).
- Non-2xx → `APIError.server(status:message:)` preferring the body's `message`
  field, falling back to the status code (R5.6). 401 is surfaced as
  `APIError.unauthorized` so `AppModel` can clear the session (R8.4).
- Transport failure → `APIError.transport(underlying:)` (R5.7).
- `FilterValue.escaped(_:)` escapes `\` then `"` and strips control characters,
  so `filter("user = \"\(FilterValue.escaped(uid))\"")` keeps its structure
  even for adversarial input (R5.8). All call sites go through
  `PeardFilter.equals(_:_:)` helpers rather than string interpolation.

### PeardCore — SharedStore (R16.5)

`UserDefaults(suiteName: "group.com.peard.app")` wrapper with typed
`widgetToken` and `apiBaseURL` accessors plus `removeWidgetToken()`. Replaces
the `PearShared` Expo module; the app writes and the widget reads the same keys
(`widgetToken`, `apiBaseUrl`) so an existing container keeps working.

### App — Configuration (R3)

`Config.xcconfig` is git-ignored with `Config.example.xcconfig` committed
(R3.5). xcconfig treats `//` as a comment, so the URL is split into scheme and
host and rejoined inside Info.plist:

```
PEARD_SERVER_SCHEME = http
PEARD_SERVER_HOST = 127.0.0.1:8090
PEARD_GOOGLE_IOS_CLIENT_ID =
```

`Info.plist` carries `PeardServerURL = $(PEARD_SERVER_SCHEME)://$(PEARD_SERVER_HOST)`
and `PeardGoogleIOSClientID = $(PEARD_GOOGLE_IOS_CLIENT_ID)`. `PeardConfig`
reads them from `Bundle.main`, falling back to `http://127.0.0.1:8090` when
absent or unparseable (R3.2). An empty Google client id is not a launch failure;
it is reported when the user taps Google sign-in (R3.4).

Cleartext HTTP for Debug only (R3.6) is a per-configuration `INFOPLIST_FILE`:
`Peard/Info-Debug.plist` adds `NSAppTransportSecurity.NSAllowsLocalNetworking`,
`Peard/Info.plist` does not. Same technique for `aps-environment`: separate
`Peard-Debug.entitlements` (`development`) and `Peard-Release.entitlements`
(`production`) selected by `CODE_SIGN_ENTITLEMENTS` per configuration (R2.3).

### App — Session (R8)

`KeychainSessionStore` stores token and user id as two generic-password items
with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, service
`com.peard.app.session`. Nothing auth-related is written to
`UserDefaults.standard` (R8.5); sign-out clears the Keychain *and* defensively
removes any legacy `UserDefaults.standard` keys left by earlier builds (Q10).

### App — Phases and routing (R9, R19)

```swift
@MainActor @Observable final class AppModel {
    enum Phase: Equatable { case loading, auth, pair(prefilledCode: String?), home(pairID: String) }
    var phase: Phase = .loading
    var membershipFailed = false        // drives the retry control (R9.6)
    func bootstrap() async
    func establish(session: Session) async
    func resolveMembership() async
    func signOut() async
    func handle(url: URL)
}
```

`resolveMembership()` requests the first `pair_members` record filtered by user
id and maps record→`.home(pairID:)`, none→`.pair`, transport failure→`.pair`
with `membershipFailed = true`. A 401 anywhere clears the session and sets
`.auth` immediately (R8.4, Q11).

`DeepLinkRouter` parses `peard://pair/{code}` (upper-cased prefill),
`peard://home` (→ home when a membership exists, else pair), and
`peard://auth/google` (handed to the pending `ASWebAuthenticationSession`);
anything else is ignored (R19.5).

### App — Auth (R6, R7)

`AuthCoordinator` is an `@Observable` actor-isolated coordinator returning
`Session(token: String, user: UserRecord)`.

Apple: `ASAuthorizationAppleIDProvider` request with `.fullName`/`.email`;
`request.nonce = SHA256(rawNonce)` hex-lowercased, raw nonce POSTed to
`/api/peard/auth/apple` as `nonce` (the server accepts either form but expects
the raw value — verified against `internal/auth/apple.go`). `ASAuthorizationError.canceled`
returns silently (R6.7).

Google: `ASWebAuthenticationSession` against
`https://accounts.google.com/o/oauth2/v2/auth` with `response_type=code`,
`scope=openid profile email`, S256 PKCE (`code_verifier` = 32 random bytes
base64url, `code_challenge` = base64url(SHA256(verifier))), redirect
`peard://auth/google`; then `POST /api/collections/users/auth-with-oauth2` with
`provider/code/codeVerifier/redirectURL`. `.canceledLogin` returns silently
(R7.6).

### App — Home (R11–R15)

`HomeModel` owns the screen state and delegates every computation to PeardCore:

- `refresh()` — 5 most recent posts (`filter: pair = "…"`, `sort: -created`,
  `perPage: 5`), reactions for the newest post, partner identity.
- `refreshTallies()` — all `type = "event"` posts for the pair
  (`perPage: 500`), split by author, into `TallyPeriods.compute(...)`.
- 30 s foreground `Timer`, `.refreshable` pull-to-refresh, and a
  `scenePhase → .active` hook all call the same pair (R11.11–R11.13).
- `logTally(kind:note:)` creates the `posts` record then, only on success,
  refreshes posts + tallies and reloads widget timelines (R12.5, Q3).
- `capturePhoto()` — `AVCaptureDevice.requestAccess(for: .video)`, a
  `UIImagePickerController` wrapper with `allowsEditing = true` for the square
  crop, `jpegData(compressionQuality: 0.6)`, multipart create with
  `pear.jpg`/`image/jpeg`. A photo post is never created without image data
  (Q13).
- `react(kind:)` — creates a `reactions` record; status 400 is treated as
  "already reacted": the existing reaction shows and no error is displayed
  (R14.4, Q4). Any other error clears the displayed reaction list and shows the
  message (Q15).

**Partner identity.** `users.viewRule` is `id = @request.auth.id`, so the client
cannot read the partner's user record and `expand=user` silently omits it — this
is why the React Native app always displayed "Partner". Peard_Server is out of
scope for this migration, so `PartnerDirectory` resolves the label by asking
`GET /api/peard/widget/feed?token=…` for `partner.name`, which the server
computes with exactly the R11.7 precedence (`display_name` → email local part →
"Partner", see `internal/widget/widget.go`). It falls back to an `expand=user`
read (correct if the rule is ever relaxed) and finally to "Partner".
`PartnerLabel.short(_:)` applies the 8-character truncation (R11.8).

### App — Widget sync (R16) and Push (R18)

`WidgetSync.sync()` POSTs `/api/peard/widget/token`, writes `widgetToken` +
`apiBaseUrl` to `SharedStore`, then `WidgetCenter.shared.reloadAllTimelines()`.
Failure leaves the container untouched and the session alive (R16.3).

`PushCoordinator` requests authorization once per installation (a
`hasRequestedNotificationAuthorization` flag in the App Group container, which
is not auth data so R8.5 is unaffected), registers with APNs when granted,
and upserts the `devices` record: look up
`push_token = "…"` first, `PATCH` when found, `POST` when not (R18.3–R18.4).
`content-available` pushes trigger posts refresh + widget reload (R18.6);
selecting a notification with `post_id` routes to home focused on that post
(R18.7). Denial is inert — every non-push feature keeps working (R18.8, Q5),
and no notification-settings UI is offered in this scope (Q18).

### PearWidget (R17)

`app/targets/pear-widget/index.swift` is the starting point (R22.7), changed to:
decode with PeardCore's `WidgetFeed`; read `SharedStore` instead of a raw
`UserDefaults(suiteName:)`; use `EventKindCatalogue.emoji(for:)`;
`containerBackground` for iOS 17 widget rendering. Families, copy, 15-minute
`.after` policy, and `peard://home` widget URL are unchanged.

### Appearance (R20)

`Assets.xcassets` colour set with light/dark variants for `PearBackground`
`#FBF7EC`, `PearAccent` `#6B8E23`, `PearTextPrimary` `#3B2E1A`,
`PearTextSecondary` `#7A6A53`, `PearError` `#B23A2E`. No
`preferredColorScheme` override anywhere, so the system setting wins with no
in-app override (R20.3, Q19). All text uses semantic `Font.TextStyle`s (Dynamic
Type), emoji-only controls carry `accessibilityLabel`, and transitions are
wrapped in `reduceMotion`-aware animation helpers.

### Debug affordances (R21)

Everything in `#if DEBUG`, so nothing ships in Release (R21.4, Q20): the
`test@peard.local` password sign-in button, the `AAAAAA` pairing hint and seeded
fake pair, and the launch-time `GET /api/health` log. The `AAAAAA` path needs
superuser writes (pairs/pair_members creation is closed to users), so it
authenticates `_superusers` with credentials read from
`PEARD_DEBUG_SUPERUSER_*` build settings, defaulting to the values the React
Native version hard-coded.

## Testing Strategy

`PeardCoreTests` (`swift test`, no simulator):

| Requirement | Test |
|---|---|
| R4.8 | encode→decode→encode fixed points for every model, incl. unknown enum cases |
| R4.9/R4.10 | `PeardDate` format→parse→format round-trip, UTC, ms precision |
| R5.8 | filter escaping keeps expression structure for quotes/backslashes/controls |
| R12.8 | `TallyPeriods` day/week-from-Monday/month/all boundaries incl. Sunday and month edges |
| R11.10 | `ElapsedTime.label` at 0 s, 59 s, 60 s, 59 min, 60 min, 23 h, 24 h, 8 d |
| R5.6/R5.7 | `APIClient` against a `URLProtocol` stub: message extraction, status fallback, 401 mapping, multipart body shape |
| R24.6 | integration test, skipped unless `PEARD_TEST_SERVER_URL` is set: sign in and create one `event` post |

The parity checklist (R24.1) lives in `.kiro/specs/swiftui-migration/parity.md`
and is filled in before Legacy_App deletion.

## Server change this migration required

The spec assumed Peard_Server was untouched. One change turned out to be
unavoidable: the initial migration built its collections with
`core.NewBaseCollection`, which in PocketBase 0.23+ does **not** add the
`created` / `updated` autodate fields. Verified against the dev database:

```
posts        -> id, pair, author, type, event_kind, note, media
pair_members -> id, pair, user, role
reactions    -> id, post, user, kind
devices      -> id, user, platform, push_token
```

With no `created` column, `?sort=-created` is rejected with 400 and no record
carries a timestamp, which makes Requirements 4.1, 4.9, 5.3, 11.1, 11.9, 11.10
and 12.8 unimplementable. The React Native app hit the same wall and swallowed
it in empty `catch` blocks — which is why its tallies were always zero, its
`pair_members` query passed an empty sort, and the widget never showed a
relative time. `internal/widget`'s own `-created` sort and `created >= today`
count were broken for the same reason.

`server/migrations/1785196800_peard_timestamps.go` adds `created` (onCreate) and
`updated` (onCreate + onUpdate) to all seven Pear'd collections, backfills
existing rows so none is left with an empty timestamp, and repoints
`idx_posts_pair_created` at `(pair, created)` to match its name. Apply it with
`make migrate` or by starting the server with `go run`.

The client is defensive regardless: `Post.created` decodes a missing or empty
value as `distantPast` (sorts last, counts only towards the all-time tally) and
`WidgetFeed.FeedPost.created` is optional, so one legacy row cannot fail a whole
list decode.

## Decisions on the clarifying questions

Implemented as answered: Q1 (Debug=development, Release=production), Q2, Q3,
Q4, Q5, Q6, Q7 (no content-type guard), Q8, Q9 (silent return to sign-in), Q10,
Q11, Q12, Q13, Q15, Q16, Q18, Q19, Q20, Q21 (Makefile after removal), Q22
(README documents the `shared/types.ts` outcome in the deletion commit).

Three answers are implemented differently because as stated they are not
achievable or would regress behaviour. Flagged rather than silently changed:

1. **Q14 — "if any post-success operation fails, revert all changes".** The
   tally is already committed on the server when these run, and
   `WidgetCenter.reloadAllTimelines()` returns no error to detect. There is
   nothing to revert and no rollback endpoint. Implemented as: creation is the
   transactional boundary; a failing *refresh* surfaces a non-blocking banner
   and leaves the created tally in place.
2. **Q17 — "require all cleanup actions to succeed before changing phase".**
   Deleting the `devices` record is a network call, so an offline or failing
   server would make sign-out impossible and leave a live session on the
   device. Implemented as: local cleanup (Keychain + widget token) always
   proceeds and the phase becomes `auth`; the device delete is best-effort and
   its failure is reported.
3. **Wire contract source.** `shared/types.ts` is deleted and
   `docs/wire-contract.md` becomes the Wire_Contract_Document (R4.11–R4.12,
   R22.6), because keeping a TypeScript file as the canonical description of a
   Swift-only client invites drift.

## Requirement 11.7 caveat

The partner label depends on a successful `POST /api/peard/widget/token` at
sign-in. Without it the label is "Partner", the same as the current React
Native behaviour. The clean fix is a server-side `users` view rule that lets
pair members read each other, which is deliberately out of scope here and is
recorded in the README roadmap instead.
