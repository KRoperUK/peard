# Migration parity checklist

Requirement 24.1. Status of each capability the Expo client had, in the native
SwiftUI app. "Verified" states how it was checked.

| Capability | Status | Verified by |
|---|---|---|
| Sign in with Apple | Implemented | Compiles against `AuthenticationServices`; nonce hashing + request body match `internal/auth/apple.go`. Not exercised end-to-end: the simulator cannot complete a real Apple authorization. |
| Sign in with Google | Implemented | PKCE S256 verifier/challenge unit-tested indirectly via `AuthCoordinator` helpers; body field names checked against PocketBase 0.39.9 `recordOAuth2LoginForm` (`provider`, `code`, `codeVerifier`, `redirectURL`). Needs a real Google client id to run. |
| Debug password sign-in | Implemented | `LocalServerIntegrationTests` signs in with `auth-with-password` against a live server. |
| Session persistence (Keychain) | Implemented | `KeychainSessionStore` writes with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; no auth data in `UserDefaults.standard`. Not covered by an automated test (needs a host app). |
| Launch phase routing | Implemented | `AppModel.bootstrap` → membership → phase; membership request verified against a live server. |
| Pairing invite | Implemented | `createInvite` decodes `PairInvite`; share text unit-tested. |
| Pairing accept | Implemented | `acceptInvite` posts `{code}`; error message extraction unit-tested. |
| Leaving a pair | Implemented | `leavePair` posts to `/api/peard/pairs/leave`; phase re-resolved from membership either way. |
| Tally logging | Implemented | Event post creation verified end-to-end in `LocalServerIntegrationTests`. |
| Tally counts (day/week/month/all) | Implemented | `TallyPeriodsTests`: Monday week start, month boundary, midnight inclusivity. Fixes a legacy bug where a week straddling a month inflated the month count. |
| Photo capture and upload | Implemented | Multipart body shape unit-tested (`fields` + `media` part, `pear.jpg`, `image/jpeg`); JPEG quality 0.6. Camera capture itself needs a device. |
| Timeline display | Implemented | 5 most recent posts read back live; elapsed-time labels unit-tested. |
| Reactions | New (absent from the Expo app) | Duplicate-400 handling implemented per Requirement 14.4; `reactions` read path exercised by the client. |
| Widget rendering | Implemented | Ported from `app/targets/pear-widget/index.swift`, now decoding `WidgetFeed` from PeardCore; feed payload decoding unit-tested including `unpaired`/`empty`. |
| Widget credential sync | Implemented | `WidgetSync` issues the token and writes `widgetToken` + `apiBaseUrl` to the App Group with the same keys the Expo module used. |
| Push registration | New (never performed by the Expo app) | `devices` upsert by `push_token`; requires a real device for APNs tokens. |
| Push handling | New | `content-available` refresh + `post_id` focus wired through `AppDelegate`. Requires APNs to exercise. |
| Deep links | Implemented | `DeepLinkTests` covers `pair`/`home`/`auth/google`/unknown; scheme registration confirmed by iOS offering "Open in Pear'd" for `peard://pair/...` on the simulator. |
| Appearance (light/dark palette) | Implemented | `Colors.xcassets` light/dark pairs, shared by app and widget; sign-in screen screenshot matches the Pear'd cream/olive palette. |
| Runtime configuration | Implemented | `PEARD_SERVER_HOST=127.0.0.1:8091` override produced `PeardServerURL=http://127.0.0.1:8091` in the built Info.plist, and the app logged `server reachable at http://127.0.0.1:8091: 200`. |

## Gaps carried forward

- **Partner display name** depends on `GET /api/peard/widget/feed`, because the
  `users` view rule (`id = @request.auth.id`) hides the partner's record. Without
  a widget token the label falls back to "Partner" — the same as the Expo app,
  which never populated it at all (it read `expand.user` without requesting
  `expand`). A server-side rule change would fix it properly.
- **Apple / Google sign-in and APNs** cannot be exercised on the simulator or
  without provider credentials; they are verified by construction against the
  server's expected request shapes.
