# Pear'd server — PocketBase used as a Go framework.
#
# Two stages so the shipped image carries no toolchain and no source. The build
# is CGO-free because PocketBase uses modernc.org/sqlite (pure Go), which is what
# makes a small static binary on Alpine possible at all — the cgo mattn/go-sqlite3
# driver would need musl headers here and glibc at runtime.
#
# Build context is ./server, so nothing from ios/ or fastlane/ is sent to the
# daemon. See .dockerignore for what is excluded from the context that remains.

# --- build ------------------------------------------------------------------
FROM golang:1.26.4-alpine AS build

WORKDIR /src

# Dependencies first: this layer is reused whenever only .go files change, and
# go.mod/go.sum are the only inputs to it.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# -trimpath keeps absolute build paths out of the binary; -s -w drop the symbol
# table and DWARF, which is most of the size. CGO_ENABLED=0 is load-bearing, not
# hygiene: without it the binary would link against musl and fail on any other
# base image.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/peard-server .

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

USER peard
WORKDIR /app
VOLUME ["/pb_data"]
EXPOSE 8090

# Migrations apply on start, so a deploy is: pull, rebuild, restart.
ENTRYPOINT ["peard-server"]
CMD ["serve", "--dir=/pb_data", "--http=0.0.0.0:8090"]
