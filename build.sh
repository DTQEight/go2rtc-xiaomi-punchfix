#!/usr/bin/env bash
# Build a go2rtc image with the Xiaomi MISS punch fix.
#
#   ./build.sh
#
# Env:
#   GO2RTC_VERSION  go2rtc tag            (default v1.9.13)
#   GO_VERSION      Go toolchain version  (default 1.24.0)
#   IMAGE           output image tag      (default go2rtc:<ver>-punchfix)
#   COMPOSE_FILE    optional compose file to (re)start after build
set -euo pipefail

WORK="$(cd "$(dirname "$0")" && pwd)"
GO2RTC_VERSION="${GO2RTC_VERSION:-v1.9.13}"
GO_VERSION="${GO_VERSION:-1.24.0}"
IMAGE="${IMAGE:-go2rtc:${GO2RTC_VERSION#v}-punchfix}"
SRC="$WORK/src"

command -v docker >/dev/null || { echo "error: docker not found" >&2; exit 1; }
command -v patch  >/dev/null || { echo "error: patch not found"  >&2; exit 1; }
docker info >/dev/null 2>&1 || {
  echo "error: cannot access the docker daemon - run with sudo or as a member of the docker group" >&2
  exit 1
}

# 1. source
if [ ! -f "$SRC/pkg/xiaomi/miss/client.go" ]; then
  echo "==> downloading go2rtc $GO2RTC_VERSION"
  mkdir -p "$SRC"
  curl -fsSL "https://github.com/AlexxIT/go2rtc/archive/refs/tags/${GO2RTC_VERSION}.tar.gz" \
    | tar xz -C "$SRC" --strip-components=1
fi

# 2. patch (idempotent)
if ! grep -q 'waitMsg != msgPunchPkt' "$SRC/pkg/xiaomi/miss/client.go"; then
  echo "==> applying punch.patch"
  patch -p1 -d "$SRC" < "$WORK/punch.patch"
fi

# 3. Go toolchain (golang.google.cn works without Docker Hub access)
if [ ! -x /tmp/go/bin/go ]; then
  echo "==> downloading go $GO_VERSION"
  curl -fsSL -o /tmp/go.tgz "https://golang.google.cn/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  rm -rf /tmp/go && tar -C /tmp -xzf /tmp/go.tgz
fi

# 4. build binary
echo "==> building"
(
  cd "$SRC"
  PATH="/tmp/go/bin:$PATH" GOPROXY="${GOPROXY:-https://goproxy.cn,direct}" CGO_ENABLED=0 \
    go build -trimpath -ldflags "-s -w" -o go2rtc .
)

# 5. image based on the official release (already local or pulled once)
BASE_TAG="${GO2RTC_VERSION#v}"
printf 'FROM ghcr.io/alexxit/go2rtc:%s\nCOPY go2rtc /usr/local/bin/go2rtc\n' "$BASE_TAG" \
  > "$WORK/Dockerfile.runtime"
docker build -f "$WORK/Dockerfile.runtime" -t "$IMAGE" "$SRC"

# 6. optional deploy
if [ -n "${COMPOSE_FILE:-}" ]; then
  echo "==> docker compose up -d"
  docker compose -f "$COMPOSE_FILE" up -d
fi

echo "built: $IMAGE"
