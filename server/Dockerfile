# Pear'd server — PocketBase used as a Go framework.
#
# Two stages so the shipped image carries no toolchain and no source. The build
# is CGO-free because PocketBase uses modernc.org/sqlite (pure Go), which is what
# makes a small static binary on Alpine possible at all — the cgo mattn/go-sqlite3
# driver would need musl headers here and glibc at runtime.
#
# The build context is the repository root, so the build can read .git and say
# which revision it is running. The root .dockerignore is an allowlist for
# exactly that reason — the repository also holds an iOS app and a local
# database, none of which belong in a build context.

# --- commit -----------------------------------------------------------------
# Reads the revision from the repository itself, rather than relying on whoever
# runs the build to remember to pass one. Komodo clones and builds, so it never
# did, and every deployed server reported its commit as "unknown".
#
# Its own stage, and the result lands in the runtime image as a file rather than
# a linker flag, so that the revision — which changes on every commit — is not
# an input to the Go build. Baking it in would rebuild the whole binary for a
# push that changed nothing but the iOS app.
#
# The same golang image as the build stage, which already has git, so nothing
# extra is pulled.
FROM golang:1.26.4-alpine AS commit

WORKDIR /repo

# The golang alpine images do not carry git, which cost a build to discover.
# Installed before .git is copied so this layer stays cached: the package set
# never changes, the repository does on every commit.
RUN apk add --no-cache git

COPY .git .git

# Separated by `;` rather than `&&`, and every step allowed to fail: this must
# never be what breaks a deploy. "unknown" is the honest answer for a build that
# cannot read a revision, and is exactly what every build used to report.
#
# `safe.directory` because the clone is owned by whoever ran the build rather
# than by root inside the container, and git refuses to read such a repository
# without being told it is fine.
RUN git config --global --add safe.directory /repo; \
    git rev-parse --short HEAD > /commit.txt 2>/dev/null || echo unknown > /commit.txt; \
    cat /commit.txt

# --- build ------------------------------------------------------------------
FROM golang:1.26.4-alpine AS build

WORKDIR /src

# Dependencies first: this layer is reused whenever only .go files change, and
# go.mod/go.sum are the only inputs to it.
COPY server/go.mod server/go.sum ./
RUN go mod download

COPY server/ .

# An explicit commit still wins where a caller supplies one — `make docker-*`
# exports it from the working tree, which is more accurate than HEAD when there
# are uncommitted changes. Left empty otherwise, so the file written by the
# commit stage above is used instead; see internal/version.
ARG PEARD_COMMIT=

# -trimpath keeps absolute build paths out of the binary; -s -w drop the symbol
# table and DWARF, which is most of the size. CGO_ENABLED=0 is load-bearing, not
# hygiene: without it the binary would link against musl and fail on any other
# base image.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath \
    -ldflags="-s -w \
      -X 'peard/internal/version.Commit=${PEARD_COMMIT}' \
      -X 'peard/internal/version.BuiltAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)'" \
    -o /out/peard-server .

# --- runtime ----------------------------------------------------------------
FROM alpine:3.23

# ca-certificates is required, not optional: the server makes outbound TLS calls
# to Apple's JWKS (identity-token and notification verification), to APNs, and to
# Let's Encrypt when PocketBase manages its own certificate. Without it every one
# of those fails with an opaque x509 error.
# tzdata so PocketBase's cron (backups, log pruning) and log timestamps can
# resolve a TZ other than UTC.
RUN apk add --no-cache ca-certificates tzdata \
    && adduser -D -u 1000 -h /app peard

# The data directory is created in the image and owned by the app user so that a
# fresh named volume inherits that ownership — Docker copies the mountpoint's
# content and ownership into a new named volume. A *bind* mount does not inherit
# it, so a host directory must be chowned to 1000:1000 by hand.
RUN mkdir -p /pb_data && chown peard:peard /pb_data

COPY --from=build /out/peard-server /usr/local/bin/peard-server
# Read at startup when no commit was linked in — see internal/version. A late,
# tiny layer on purpose: it changes on every commit, and everything expensive is
# already above it.
COPY --from=commit /commit.txt /app/commit

USER peard
WORKDIR /app
VOLUME ["/pb_data"]
EXPOSE 8090

# Migrations apply on start, so a deploy is: pull, rebuild, restart.
ENTRYPOINT ["peard-server"]
CMD ["serve", "--dir=/pb_data", "--http=0.0.0.0:8090"]
