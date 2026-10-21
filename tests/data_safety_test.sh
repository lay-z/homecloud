#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/.env" <<EOF
BASE_DOMAIN=example.test
ACME_EMAIL=admin@example.test
DATA_ROOT=$TMP/data
TZ=UTC
PUID=1000
PGID=1000
ENABLED_SERVICES=jellyfin
EOF

cp -a "$ROOT/traefik" "$TMP/traefik"
cp -a "$ROOT/jellyfin" "$TMP/jellyfin"

cat > "$TMP/jellyfin/.env" <<EOF
JELLYFIN_MEDIA_PATH=$TMP/media
EOF
: > "$TMP/jellyfin/.secrets"

render() {
  local service="$1"
  local args=(--env-file "$TMP/.env" -f "$TMP/$service/compose.yaml")

  if [[ -f "$TMP/$service/.env" ]]; then
    args+=(--env-file "$TMP/$service/.env")
  fi
  if [[ -f "$TMP/$service/.secrets" ]]; then
    args+=(--env-file "$TMP/$service/.secrets")
  fi

  docker compose "${args[@]}" config --format json
}

for service in traefik jellyfin; do
  rendered="$(render "$service")"
  if grep -Eq '"type"[[:space:]]*:[[:space:]]*"volume"' <<< "$rendered"; then
    printf 'FAIL: %s has a named or anonymous volume\n' "$service" >&2
    exit 1
  fi
done

printf 'data safety tests passed\n'
