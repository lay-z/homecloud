#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

write_root_env() {
  cat > "$TMP/.env" <<EOF
BASE_DOMAIN=example.test
ACME_EMAIL=admin@example.test
DATA_ROOT=$TMP/data
TZ=UTC
PUID=1000
PGID=1000
ENABLED_SERVICES=jellyfin
EOF
}

copy_service() {
  local service="$1"
  cp -a "$ROOT/$service" "$TMP/$service"
  mkdir -p "$TMP/data/$service"
}

install_fixture() {
  local service="$1"
  cp "$ROOT/tests/fixtures/$service.env" "$TMP/$service/.env"
  cp "$ROOT/tests/fixtures/$service.secrets" "$TMP/$service/.secrets"
  chmod 600 "$TMP/$service/.secrets"
}

render_service() {
  local service="$1"
  shift
  local args=(--env-file "$TMP/.env" -f "$TMP/$service/compose.yaml")
  local file

  for file in "$@"; do
    args+=(--env-file "$TMP/$service/$file")
  done

  docker compose "${args[@]}" config
}

render_service_json() {
  local service="$1"
  shift
  local args=(--env-file "$TMP/.env" -f "$TMP/$service/compose.yaml")
  local file

  for file in "$@"; do
    args+=(--env-file "$TMP/$service/$file")
  done

  docker compose "${args[@]}" config --format json
}

assert_render_contains() {
  local rendered="$1"
  local needle="$2"
  local message="$3"

  grep -Fq -- "$needle" <<< "$rendered" || fail "$message"
}

assert_no_volumes() {
  local rendered="$1"

  if grep -Eq '"type"[[:space:]]*:[[:space:]]*"volume"' <<< "$rendered"; then
    fail "rendered compose has a named or anonymous volume"
  fi
}
