#!/usr/bin/env sh
# scripted/written by Robert Bopko (github.com/zeroznet) with Boba Bott (Claude Opus 4.7)

set -eu
set -o pipefail

UPSTREAM_REPO_URL="https://github.com/sipeed/picoclaw.git"
DEFAULT_SOURCE_DIR="${HOME}/src/picoclaw"
DEFAULT_REF="main"

APPLY_SILENT_PATCH=0
WITH_GOOLM=1
INSTALL_DEPS=0

SOURCE_DIR="${DEFAULT_SOURCE_DIR}"
REF="${DEFAULT_REF}"
PATCH_BUILD_BRANCH="build-silent-processing"

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") [options]

Options:
  --dir PATH           Clone/update upstream PicoClaw into PATH (default: ${DEFAULT_SOURCE_DIR})
  --ref NAME           Upstream ref (branch or tag) to build from (default: ${DEFAULT_REF})
  --branch NAME        Legacy alias for --ref
  --apply-pr-2127      Apply a local forward-port of PR #2127 (silent_processing) onto latest upstream
  --without-goolm      Build with tags: stdjson,whatsapp_native (not recommended on current upstream)
  --install-deps       Try to install missing deps with pkg (git go ca_root_nss)
  -h, --help           Show this help

What it does:
  1. Clone or update latest PicoClaw from GitHub
  2. Optionally apply a local silent_processing patch on top of latest upstream
  3. Reuse/create Go build environment under ~/go and ~/.cache/go-build
  4. Run: go mod download && go mod verify
  5. Run: go generate ./...
  6. Build FreeBSD amd64 binary with native WhatsApp support
  7. Smoke-test the binary and verify whatsmeow is linked
  8. Back up an existing built binary before replacing it
USAGE
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
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
    --ref)
      [ $# -ge 2 ] || die "Missing value for --ref"
      REF="$2"
      shift 2
      ;;
    --branch)
      [ $# -ge 2 ] || die "Missing value for --branch"
      REF="$2"
      shift 2
      ;;
    --apply-pr-2127)
      APPLY_SILENT_PATCH=1
      shift
      ;;
    --without-goolm)
      WITH_GOOLM=0
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

  set --
  has_cmd git || set -- "$@" git
  has_cmd go || set -- "$@" go
  pkg info -e ca_root_nss >/dev/null 2>&1 || set -- "$@" ca_root_nss

  [ "$#" -gt 0 ] || return 0

  log ">>> Installing missing packages: $*"
  if has_cmd sudo; then
    sudo pkg install -y "$@"
  else
    pkg install -y "$@"
  fi
}

init_go_env() {
  GOPATH_DEFAULT=$(go env GOPATH 2>/dev/null || printf '%s/go' "$HOME")
  GOMODCACHE_DEFAULT=$(go env GOMODCACHE 2>/dev/null || printf '%s/pkg/mod' "${GOPATH_DEFAULT}")
  GOCACHE_DEFAULT=$(go env GOCACHE 2>/dev/null || printf '%s/.cache/go-build' "$HOME")

  : "${GOPATH:=${GOPATH_DEFAULT}}"
  : "${GOMODCACHE:=${GOMODCACHE_DEFAULT}}"
  : "${GOCACHE:=${GOCACHE_DEFAULT}}"
  : "${GOPROXY:=https://proxy.golang.org,direct}"

  export GOPATH GOMODCACHE GOCACHE GOPROXY

  mkdir -p "${GOPATH}" "${GOMODCACHE}" "${GOCACHE}"

  log ">>> Go environment"
  log "    GOPATH=${GOPATH}"
  log "    GOMODCACHE=${GOMODCACHE}"
  log "    GOCACHE=${GOCACHE}"
}

fetch_upstream_refs_in_repo() {
  repo_path="$1"
  git -C "${repo_path}" fetch origin --prune || die "Failed to fetch origin branches in ${repo_path}"
  git -C "${repo_path}" fetch origin --tags --force || die "Failed to fetch origin tags in ${repo_path}"
}

fetch_upstream_refs() {
  git fetch origin --prune || die "Failed to fetch origin branches"
  git fetch origin --tags --force || die "Failed to fetch origin tags"
}

resolve_upstream_ref() {
  if git show-ref --verify --quiet "refs/remotes/origin/${REF}"; then
    printf '%s' "origin/${REF}"
    return 0
  fi

  if git show-ref --verify --quiet "refs/tags/${REF}"; then
    printf '%s' "refs/tags/${REF}"
    return 0
  fi

  die "Upstream ref not found as branch or tag: ${REF}"
}

clone_or_update_upstream() {
  source_parent=$(dirname "${SOURCE_DIR}")
  mkdir -p "${source_parent}"

  if [ -d "${SOURCE_DIR}/.git" ]; then
    log ">>> Updating existing repo: ${SOURCE_DIR}"
    fetch_upstream_refs_in_repo "${SOURCE_DIR}"
    return 0
  fi

  if [ -e "${SOURCE_DIR}" ]; then
    die "Target path exists and is not a git repo: ${SOURCE_DIR}"
  fi

  log ">>> Cloning repo into: ${SOURCE_DIR}"
  git clone "${UPSTREAM_REPO_URL}" "${SOURCE_DIR}"
  fetch_upstream_refs_in_repo "${SOURCE_DIR}"
}

build_tags() {
  if [ "${WITH_GOOLM}" -eq 1 ]; then
    printf '%s' 'goolm,stdjson,whatsapp_native'
  else
    printf '%s' 'stdjson,whatsapp_native'
  fi
}

prepare_repo_state() {
  fetch_upstream_refs
  TARGET_REF=$(resolve_upstream_ref)

  # Treat the source repo as a disposable upstream cache/build tree
  # Always discard tracked/untracked changes before switching refs so
  # repeated --apply-pr-2127 runs stay deterministic
  if [ -n "$(git status --porcelain)" ]; then
    warn "Discarding local changes in ${SOURCE_DIR}"
  fi
  git reset --hard
  git clean -fd

  if [ "${APPLY_SILENT_PATCH}" -eq 1 ]; then
    log ">>> Creating fresh build branch ${PATCH_BUILD_BRANCH} from ${TARGET_REF}"
    git checkout -B "${PATCH_BUILD_BRANCH}" "${TARGET_REF}"
    git branch --unset-upstream "${PATCH_BUILD_BRANCH}" >/dev/null 2>&1 || true
    return 0
  fi

  case "${TARGET_REF}" in
    origin/*)
      log ">>> Resetting local ${REF} to latest ${TARGET_REF}"
      if git show-ref --verify --quiet "refs/heads/${REF}"; then
        git checkout "${REF}"
      else
        git checkout -b "${REF}" "${TARGET_REF}"
      fi
      git reset --hard "${TARGET_REF}"
      ;;
    refs/tags/*)
      log ">>> Checking out tag ${REF}"
      git checkout --detach "${TARGET_REF}"
      ;;
    *)
      die "Unsupported resolved target ref: ${TARGET_REF}"
      ;;
  esac
}

apply_silent_processing_patch() {
  [ "${APPLY_SILENT_PATCH}" -eq 1 ] || return 0

  if grep -q 'silent_processing' pkg/config/config.go 2>/dev/null; then
    log ">>> silent_processing already present in source tree; skipping local patch"
    return 0
  fi

  PATCHER_GO=$(mktemp "${TMPDIR:-/tmp}/picoclaw-silent-patcher.XXXXXX.go")

  cat > "${PATCHER_GO}" <<'EOF_PATCHER'
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

func mustRead(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	return string(b)
}

func mustWrite(path, s string) {
	if err := os.WriteFile(path, []byte(s), 0644); err != nil {
		panic(err)
	}
}

func replaceOnce(s, old, new, label string) string {
	if strings.Contains(s, new) {
		return s
	}
	if !strings.Contains(s, old) {
		panic(fmt.Sprintf("pattern not found for %s", label))
	}
	return strings.Replace(s, old, new, 1)
}

func replaceRegexOnce(s string, re *regexp.Regexp, repl, label string) string {
	if !re.MatchString(s) {
		panic(fmt.Sprintf("regex pattern not found for %s", label))
	}
	return re.ReplaceAllString(s, repl)
}

func main() {
	if len(os.Args) != 2 {
		panic("usage: patcher <repo-path>")
	}
	repo := os.Args[1]

	// pkg/config/config.go
	cfgPath := filepath.Join(repo, "pkg/config/config.go")
	cfg := mustRead(cfgPath)
	cfg = replaceOnce(
		cfg,
		"\tSplitOnMarker             bool               `json:\"split_on_marker\"                  env:\"PICOCLAW_AGENTS_DEFAULTS_SPLIT_ON_MARKER\"` // split messages on <|[SPLIT]|> marker\n\tContextManager            string             `json:\"context_manager,omitempty\"        env:\"PICOCLAW_AGENTS_DEFAULTS_CONTEXT_MANAGER\"`\n",
		"\tSplitOnMarker             bool               `json:\"split_on_marker\"                  env:\"PICOCLAW_AGENTS_DEFAULTS_SPLIT_ON_MARKER\"` // split messages on <|[SPLIT]|> marker\n\tSilentProcessing          bool               `json:\"silent_processing,omitempty\"      env:\"PICOCLAW_AGENTS_DEFAULTS_SILENT_PROCESSING\"`\n\tContextManager            string             `json:\"context_manager,omitempty\"        env:\"PICOCLAW_AGENTS_DEFAULTS_CONTEXT_MANAGER\"`\n",
		"config silent field",
	)
	mustWrite(cfgPath, cfg)

	// pkg/agent/instance.go
	instPath := filepath.Join(repo, "pkg/agent/instance.go")
	inst := mustRead(instPath)
	inst = replaceOnce(
		inst,
		"\t// LightProvider is the concrete provider instance for the configured light model.\n\t// It is only used when routing selects the light tier for a turn.\n\tLightProvider providers.LLMProvider\n",
		"\t// LightProvider is the concrete provider instance for the configured light model.\n\t// It is only used when routing selects the light tier for a turn.\n\tLightProvider providers.LLMProvider\n\t// SilentProcessing suppresses the automatic empty-response fallback when the\n\t// LLM produces no text output. The agent still runs fully and sends a\n\t// response when the LLM produces text.\n\tSilentProcessing bool\n",
		"instance silent field",
	)
	if !strings.Contains(inst, "SilentProcessing:") {
		reLightAssign := regexp.MustCompile(`(?m)^(\s*LightProvider:\s+lightProvider,\n)`)
		inst = replaceRegexOnce(inst, reLightAssign, "${1}\t\tSilentProcessing:          defaults.SilentProcessing,\n", "instance constructor")
	}
	mustWrite(instPath, inst)

	// pkg/agent/loop.go
	loopPath := filepath.Join(repo, "pkg/agent/loop.go")
	loop := mustRead(loopPath)
	loop = replaceOnce(
		loop,
		"\t})\n\n\topts := processOptions{\n\t\tSessionKey:        sessionKey,\n",
		"\t})\n\n\tresolvedDefaultResponse := defaultResponse\n\tif agent.SilentProcessing {\n\t\tresolvedDefaultResponse = \"\"\n\t}\n\n\topts := processOptions{\n\t\tSessionKey:        sessionKey,\n",
		"loop resolvedDefaultResponse",
	)
	loop = replaceOnce(
		loop,
		"\t\tDefaultResponse:   defaultResponse,\n",
		"\t\tDefaultResponse:   resolvedDefaultResponse,\n",
		"loop opts default response",
	)
	loop = replaceOnce(
		loop,
		"\tif finalContent == \"\" {\n",
		"\tif finalContent == \"\" && ts.opts.DefaultResponse != \"\" {\n",
		"loop finalContent condition",
	)
	loop = replaceOnce(
		loop,
		"\tif !ts.opts.NoHistory {\n\t\tfinalMsg := providers.Message{Role: \"assistant\", Content: finalContent}\n\t\tts.agent.Sessions.AddMessage(ts.sessionKey, finalMsg.Role, finalMsg.Content)\n\t\tts.recordPersistedMessage(finalMsg)\n\t\tts.ingestMessage(turnCtx, al, finalMsg)\n\t\tif err := ts.agent.Sessions.Save(ts.sessionKey); err != nil {\n",
		"\tif !ts.opts.NoHistory {\n\t\tif finalContent != \"\" {\n\t\t\tfinalMsg := providers.Message{Role: \"assistant\", Content: finalContent}\n\t\t\tts.agent.Sessions.AddMessage(ts.sessionKey, finalMsg.Role, finalMsg.Content)\n\t\t\tts.recordPersistedMessage(finalMsg)\n\t\t\tts.ingestMessage(turnCtx, al, finalMsg)\n\t\t}\n\t\tif err := ts.agent.Sessions.Save(ts.sessionKey); err != nil {\n",
		"loop history save",
	)
	mustWrite(loopPath, loop)
}
EOF_PATCHER

  log ">>> Applying local silent_processing patch via Go patcher"
  if ! go run "${PATCHER_GO}" "${SOURCE_DIR}"; then
    rm -f "${PATCHER_GO}" >/dev/null 2>&1 || true
    die "Failed to apply local silent_processing patch"
  fi

  rm -f "${PATCHER_GO}" >/dev/null 2>&1 || true
}

backup_existing_binary() {
  [ -f "${OUT_BIN}" ] || return 0

  BACKUP_DIR="${OUT_DIR}/backups"
  BACKUP_STAMP=$(date +%Y%m%d-%H%M%S)
  BACKUP_BIN="${BACKUP_DIR}/$(basename "${OUT_BIN}").${BACKUP_STAMP}.bak"

  mkdir -p "${BACKUP_DIR}"
  cp -p "${OUT_BIN}" "${BACKUP_BIN}" || die "Failed to back up existing binary to ${BACKUP_BIN}"
  log ">>> Backed up existing binary to: ${BACKUP_BIN}"
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
    warn "Stub string still present in binary output; proceeding because go version -m confirms whatsmeow is linked."
  fi
}

verify_silent_processing_patch() {
  [ "${APPLY_SILENT_PATCH}" -eq 1 ] || return 0

  log ">>> Verifying silent_processing markers"
  grep -Rqs 'silent_processing' "${SOURCE_DIR}" || die "silent_processing not found in source tree after patch"

  if ! strings "${OUT_BIN}" | grep -qi 'silent_processing'; then
    warn "Built binary does not visibly expose 'silent_processing' in strings output. Source tree has it, so build may still be fine."
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
need_cmd mktemp

init_go_env
clone_or_update_upstream
cd "${SOURCE_DIR}"
prepare_repo_state
apply_silent_processing_patch

BUILD_TAGS=$(build_tags)
VER=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT=$(git rev-parse --short=8 HEAD 2>/dev/null || echo dev)
BTIME=$(date +%FT%T%z)
GOVER=$(go version | awk '{print $3}')
CURRENT_BRANCH=$(git describe --tags --exact-match 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)
OUT_DIR="${SOURCE_DIR}/build"
OUT_BIN="${OUT_DIR}/picoclaw-freebsd-amd64"
OUT_TMP="${OUT_BIN}.new.$$"

cleanup_tmp() {
  [ -n "${OUT_TMP:-}" ] && [ -f "${OUT_TMP}" ] && rm -f "${OUT_TMP}"
}
trap cleanup_tmp EXIT INT TERM HUP

mkdir -p "${OUT_DIR}"

log ">>> Using branch: ${CURRENT_BRANCH}"
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
  -o "${OUT_TMP}" \
  ./cmd/picoclaw

[ -x "${OUT_TMP}" ] || die "Build failed: binary missing or not executable"

# Verify the freshly built binary before replacing the current one
OUT_BIN_CHECK="${OUT_BIN}"
OUT_BIN="${OUT_TMP}"
smoke_test_binary
verify_whatsapp_native
verify_silent_processing_patch
OUT_BIN="${OUT_BIN_CHECK}"
unset OUT_BIN_CHECK

backup_existing_binary
mv -f "${OUT_TMP}" "${OUT_BIN}" || die "Failed to replace old binary with new build"

SIZE=$(stat -f %z "${OUT_BIN}" 2>/dev/null || echo unknown)

printf '\n'
printf 'Build OK\n'
printf 'Repo:        %s\n' "${SOURCE_DIR}"
printf 'Branch:      %s\n' "${CURRENT_BRANCH}"
printf 'Binary:      %s\n' "${OUT_BIN}"
printf 'Size:        %s bytes\n' "${SIZE}"
printf 'Tags:        %s\n' "${BUILD_TAGS}"
printf 'Silent patch:%s\n' "$( [ "${APPLY_SILENT_PATCH}" -eq 1 ] && printf ' enabled' || printf ' disabled' )"
printf '\n'
printf 'Next step:\n'
printf '  %s gateway\n' "${OUT_BIN}"
