#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export PATH="$TMP/bin:$PATH"
export DOCKER_LOG="$TMP/docker.log"
mkdir -p "$TMP/bin"

cat > "$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
if [[ "${DOCKER_VOLUME_JSON:-0}" == "1" && "$*" == *"config --format json"* ]]; then
  printf '{"services":{"x":{"volumes":[{"type":"volume"}]}}}\n'
fi
if [[ "${DOCKER_PS_FAIL:-0}" == "1" && "$*" == *"ps -q"* ]]; then
  exit 1
fi
if [[ -n "${DOCKER_MISSING_VOLUME:-}" && "$*" == "volume inspect $DOCKER_MISSING_VOLUME" ]]; then
  exit 1
fi
if [[ -n "${DOCKER_BUSY_VOLUME:-}" && "$*" == "ps -q --filter volume=$DOCKER_BUSY_VOLUME" ]]; then
  printf 'fake-container-id\n'
  exit 0
fi
exit 0
FAKE
chmod +x "$TMP/bin/docker"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -e "$1" ]] || fail "missing file: $1"
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

make_repo() {
  local dir="$1"
  mkdir -p "$dir/traefik" "$dir/jellyfin"
  cp "$ROOT/stack" "$dir/stack"
  cp "$ROOT/.env.example" "$dir/.env.example"
  cp "$ROOT/.gitignore" "$dir/.gitignore"
  chmod +x "$dir/stack"

  cat > "$dir/traefik/compose.yaml" <<'YAML'
name: traefik
services:
  traefik:
    image: traefik
YAML

  cat > "$dir/jellyfin/compose.yaml" <<'YAML'
name: jellyfin
services:
  jellyfin:
    image: jellyfin
YAML

  cat > "$dir/jellyfin/.env.example" <<'ENV'
JELLYFIN_MEDIA_PATH=/tmp/media
ENV

  cat > "$dir/jellyfin/.secrets.example" <<'SECRETS'
JELLYFIN_SECRET=
SECRETS
}
