---
inclusion: always
---

# peard

iOS/SwiftUI app (`ios/`) plus a Go/PocketBase server (`server/`).

## Gate

Use the Makefile: `make lint`, `make test`, `make test-app`, `make fmt`.
Tooling: xcodebuild, xcodegen, swiftlint, gofmt, bundle/fastlane. The
`xcodebuild` MCP and the swiftui-* skills are available.

## Trust boundary

- `KRoperUK/peard` on github.com is PUBLIC. Any push there is publishing: only
  this repo's own work belongs in it, never secrets or personal data.
- `main` is the default branch and is protected by a ruleset. Work on feature
  branches and open PRs; never push or force-push to `main`.
- Real credentials live only in gitignored `.env`, `.env.*` and `*.key` files.
  `server/.env.example` is the template. CI secrets are referenced by name only:
  `APP_STORE_CONNECT_API_*`, `KOMODO_STACK_WEBHOOK_SECRET`,
  `OPENROUTER_API_KEY`, `RELEASE_PLEASE_TOKEN`.

## Deploys: ask first

These publish or affect live systems, so confirm before running:
- TestFlight / App Store Connect (fastlane, `make app-release`).
- `docker push` (Docker Hub is a public registry).
- The Komodo stack webhook.
- Anything touching `peard.kroper.uk` (the production host), or any host or
  namespace with `prod` / `production` in its name.
