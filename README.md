# Pear'd 🍐

Moments and tallies shared with your favourite person — like a locket for photos,
a counter for the beers, and a nod for the loo.

## Structure

```
peard/
├── server/       PocketBase used as a Go framework (extended)
├── app/          Expo (React Native) – iOS app + WidgetKit target
└── shared/       TypeScript types shared across boundaries
```

## Quick start

### 1. Server

```bash
cd server
cp .env.example .env          # (optional) set PEARD_APP_URL, Apple audience, etc.
go run . serve --http=127.0.0.1:8090
```

The first run auto-applies the Go migrations (pairs, posts, reactions, etc.).

**Admin UI:** http://127.0.0.1:8090/_/ – create a superuser on first visit.

### 2. App (iOS)

```bash
cd app
cp .env.example .env           # set EXPO_PUBLIC_PB_URL and Google client id
npm start                      # or npx expo run:ios
```

If CocoaPods is installed run `npx expo prebuild --platform ios` to generate the
native project with the WidgetKit extension target (powered by
`@bacons/apple-targets`).

## Auth providers

### Sign in with Apple (native)

The app calls the native Apple dialog (`expo-apple-authentication`) and POSTs
the identity token to `POST /api/peard/auth/apple`. The server verifies it
against Apple's JWKS, creates or links the user by verified email, and returns
a PocketBase auth token.

- Required env: `PEARD_APPLE_AUDIENCE` (default `com.peard.app` – your iOS bundle id).
- The `_externalAuths` collection is kept in sync so PB's built-in
  OAuth2/OIDC flows recognise the link.

### Sign in with Google (OAuth2 code + PKCE)

The app runs a standard PKCE flow (`expo-auth-session`) and calls PocketBase's
native `authWithOAuth2Code`. PocketBase links by verified email.

- Create a **Google iOS OAuth client** (bundle `com.peard.app`) in the Google
  Cloud Console.
- Configure the client id/secret on the `users` auth collection in the PB
  Dashboard (*Collections > users > Options > OAuth2 > Google*).
- Set `EXPO_PUBLIC_GOOGLE_IOS_CLIENT_ID` in `app/.env`.

## WidgetKit

The home-screen widget fetches your partner's latest photo/tally via
`GET /api/peard/widget/feed` using a revocable widget token stored in the App
Group container (`group.com.peard.app`).

- After sign-in the app issues a token and writes it to App Group via the
  `PearShared` native module, then calls `WidgetCenter.reloadAllTimelines()`.
- Widget timelines refresh every ~15 min plus on every new post (best-effort,
  subject to the system's reload budget).

## Push notifications (APNs)

Set the `PEARD_APNS_*` env vars to enable:
- A visible alert + silent background nudge on new posts.
- A visible alert on reactions.

Without APNs the app still works — it just won't receive live pushes.

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

The React Native app is shared; the widget layer needs a second implementation
(Jetpack Glance, equivalent App Group → SharedPreferences). The PocketBase
backend is unchanged. FCM replaces APNs. Google OAuth works as-is. Apple sign-in
on Android requires Apple's web-service config or can be omitted.

## Roadmap

- [ ] Live Activity for "instant photo drop" moments (ActivityKit push-to-update)
- [ ] Interactive widget buttons (iOS 17+ App Intents)
- [ ] Android widget (Jetpack Glance)
- [ ] Groups (the `pair_members` join table is already many-to-many)
- [ ] Media storage (S3 compatible via PB filesystem settings)
