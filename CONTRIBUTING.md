# Contributing

Thanks for looking. This is short on purpose: the [README](README.md) is the
real manual, and everything here points into it.

## Setting up

Follow the README's [Quick start](README.md#quick-start): the server, the iOS
app, the tests and the git hooks, in that order. `make hooks` installs the
pre-commit and pre-push hooks, which run the cheap half of CI before a commit
and the expensive half before a push. It is also run by `make project`, but
`brew install pre-commit` has to happen first or the hooks stay inactive.

## Before you open a pull request

```bash
make lint   # go vet, gofmt, project.yml, SwiftLint: what CI checks
make test   # PeardCore unit tests
cd server && go test ./...
```

`make test-app` runs the app-target tests on a simulator. The pre-push hook
runs them when `ios/` changes, and CI runs them on `main`.

If you change what goes over the wire, update
[`docs/wire-contract.md`](docs/wire-contract.md) in the same pull request. If a
change can only be checked on a real device, add it to
[`docs/device-checklist.md`](docs/device-checklist.md).

### Words a person reads

User-facing copy in the app target (`ios/Peard`) goes through the String
Catalog, `ios/Peard/Localizable.xcstrings`. English is the base language and the
English text itself is the key. SwiftUI's literal initialisers (`Text("…")`,
`Button("…")`, `.navigationTitle("…")`) are looked up in the catalog already.
Copy held as a plain `String` — an alert, a banner, a VoiceOver label, a branch
of a ternary — needs `String(localized: "…")`. Write one whole sentence per
string, with `\(…)` for the variable parts, never fragments joined together.

`make lint` fails on the cases that would slip past the catalog (the
`unlocalized_*` rules in `.swiftlint.yml`). Building in the Xcode IDE adds new keys
to the catalog (command-line `xcodebuild` does not); commit the change. The widget, watch and other extensions, and
`PeardCore`, are not extracted yet.

## Commit messages

Commits follow [Conventional Commits](https://www.conventionalcommits.org/),
for example `fix(ios): …`, `feat(server): …` or `docs: …`. release-please is
live: it reads these messages to choose the next version and to write
`CHANGELOG.md`, so a `feat:` or `fix:` line is what testers see in TestFlight's
"What to Test". The README's
[Releases and changelog](README.md#releases-and-changelog) section lists which
types bump the version and which are hidden.

Pull requests are merged, not squashed, so every commit on the branch ends up
in that history. Give each one a proper message, and say *why* in the body. The
diff already says what.

## Security

Please do not report vulnerabilities in public issues. [SECURITY.md](SECURITY.md)
explains how to report one privately.
