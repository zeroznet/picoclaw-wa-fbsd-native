#!/usr/bin/env sh
# scripted by Robert Bopko (github.com/zeroznet) with Boba Bott (GPT-5.4-Thinking by OpenAI)

set -eu

UPSTREAM_REPO_URL="https://github.com/sipeed/picoclaw.git"
DEFAULT_SOURCE_DIR="${HOME}/src/picoclaw"

WITH_GOOLM=0
INSTALL_DEPS=0
SOURCE_DIR="${DEFAULT_SOURCE_DIR}"

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") [options]

Options:
  --dir PATH         Clone/update upstream PicoClaw into PATH (default: ${DEFAULT_SOURCE_DIR})
  --with-goolm       Build with tags: goolm,stdjson,whatsapp_native
  --install-deps     Try to install missing deps with pkg (git go ca_root_nss)
  -h, --help         Show this help

What it does:
  1. Clone or update latest PicoClaw from GitHub
  2. Run: go mod download && go mod verify
  3. Run: go generate ./...
  4. Build FreeBSD amd64 binary with native WhatsApp support
  5. Smoke-test the binary and verify whatsmeow is linked
USAGE
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

need_cmd() {
  has_cmd "$1" || die "Missing required command: $1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      [ $# -ge 2 ] || die "Missing value for --dir"
      SOURCE_DIR="$2"
      shift 2
      ;;
    --with-goolm)
      WITH_GOOLM=1
      shift
      ;;
    --install-deps)
      INSTALL_DEPS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown option: $1"
      ;;
  esac
done

maybe_install_deps() {
  [ "${INSTALL_DEPS}" -eq 1 ] || return 0

  has_cmd pkg || die "pkg not found; cannot auto-install dependencies"

  PKGS=""
  has_cmd git || PKGS="${PKGS} git"
  has_cmd go || PKGS="${PKGS} go"

  if ! pkg info -e ca_root_nss >/dev/null 2>&1; then
    PKGS="${PKGS} ca_root_nss"
  fi

  [ -n "${PKGS}" ] || return 0

  log ">>> Installing missing packages:${PKGS}"
  if has_cmd sudo; then
    sudo pkg install -y ${PKGS}
  else
    pkg install -y ${PKGS}
  fi
}

clone_or_update_upstream() {
  source_parent=$(dirname "${SOURCE_DIR}")
  mkdir -p "${source_parent}"

  if [ -d "${SOURCE_DIR}/.git" ]; then
    log ">>> Updating existing repo: ${SOURCE_DIR}"
    git -C "${SOURCE_DIR}" fetch --all --tags --prune
    git -C "${SOURCE_DIR}" checkout main
    git -C "${SOURCE_DIR}" pull --ff-only
    return 0
  fi

  if [ -e "${SOURCE_DIR}" ]; then
    die "Target path exists and is not a git repo: ${SOURCE_DIR}"
  fi

  log ">>> Cloning repo into: ${SOURCE_DIR}"
  git clone "${UPSTREAM_REPO_URL}" "${SOURCE_DIR}"
}

build_tags() {
  if [ "${WITH_GOOLM}" -eq 1 ]; then
    printf '%s' 'goolm,stdjson,whatsapp_native'
  else
    printf '%s' 'stdjson,whatsapp_native'
  fi
}

smoke_test_binary() {
  log ">>> Smoke test: version/help"
  if ! "${OUT_BIN}" version >/dev/null 2>&1; then
    "${OUT_BIN}" --help >/dev/null 2>&1 || {
      die "Smoke test failed: binary does not answer to 'version' or '--help'"
    }
  fi
}

verify_whatsapp_native() {
  log ">>> Verifying native WhatsApp linkage"
  go version -m "${OUT_BIN}" | grep -qi 'go.mau.fi/whatsmeow' || {
    die "Build succeeded but whatsmeow not found in build metadata"
  }

  if strings "${OUT_BIN}" | grep -qi 'whatsapp native not compiled in'; then
    log "Warning: stub string still present in binary output; proceeding because go version -m confirms whatsmeow is linked."
  fi
}

maybe_install_deps

need_cmd git
need_cmd go
need_cmd awk
need_cmd date
need_cmd grep
need_cmd strings
need_cmd stat

: "${GOPROXY:=https://proxy.golang.org,direct}"
export GOPROXY

clone_or_update_upstream
cd "${SOURCE_DIR}"

BUILD_TAGS=$(build_tags)
VER=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT=$(git rev-parse --short=8 HEAD 2>/dev/null || echo dev)
BTIME=$(date +%FT%T%z)
GOVER=$(go version | awk '{print $3}')
OUT_DIR="${SOURCE_DIR}/build"
OUT_BIN="${OUT_DIR}/picoclaw-freebsd-amd64"

mkdir -p "${OUT_DIR}"

log ">>> Using tags: ${BUILD_TAGS}"
log ">>> Downloading modules"
go mod download

log ">>> Verifying modules"
go mod verify

log ">>> Running go generate"
go generate ./...

log ">>> Building PicoClaw"
CGO_ENABLED=0 GOOS=freebsd GOARCH=amd64 \
  go build -v \
  -trimpath \
  -tags "${BUILD_TAGS}" \
  -ldflags "-X github.com/sipeed/picoclaw/pkg/config.Version=${VER} -X github.com/sipeed/picoclaw/pkg/config.GitCommit=${COMMIT} -X github.com/sipeed/picoclaw/pkg/config.BuildTime=${BTIME} -X github.com/sipeed/picoclaw/pkg/config.GoVersion=${GOVER} -s -w" \
  -o "${OUT_BIN}" \
  ./cmd/picoclaw

[ -x "${OUT_BIN}" ] || die "Build failed: binary missing or not executable"

smoke_test_binary
verify_whatsapp_native

SIZE=$(stat -f %z "${OUT_BIN}" 2>/dev/null || echo unknown)

echo
echo "Build OK"
echo "Repo:   ${SOURCE_DIR}"
echo "Binary: ${OUT_BIN}"
echo "Size:   ${SIZE} bytes"
echo "Tags:   ${BUILD_TAGS}"
echo
echo "Next step:"
echo "  ${OUT_BIN} gateway"
