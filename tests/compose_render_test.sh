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

traefik="$(docker compose --env-file "$TMP/.env" -f "$TMP/traefik/compose.yaml" config)"

grep -Fq 'certificatesresolvers.le.acme.email=admin@example.test' <<< "$traefik" \
  || { printf 'FAIL: Traefik ACME email missing\n' >&2; exit 1; }
grep -Fq 'entrypoints.websecure.address=:443' <<< "$traefik" \
  || { printf 'FAIL: Traefik websecure entrypoint missing\n' >&2; exit 1; }
grep -Fq 'providers.docker.exposedByDefault=false' <<< "$traefik" \
  || { printf 'FAIL: Traefik exposedByDefault missing\n' >&2; exit 1; }
grep -Fq '/acme.json' <<< "$traefik" \
  || { printf 'FAIL: Traefik acme.json mount missing\n' >&2; exit 1; }

cp -a "$ROOT/jellyfin" "$TMP/jellyfin"

cat > "$TMP/jellyfin/.env" <<EOF
JELLYFIN_MEDIA_PATH=$TMP/media
EOF
: > "$TMP/jellyfin/.secrets"

jellyfin="$(docker compose \
  --env-file "$TMP/.env" \
  --env-file "$TMP/jellyfin/.env" \
  --env-file "$TMP/jellyfin/.secrets" \
  -f "$TMP/jellyfin/compose.yaml" \
  config)"

grep -Fq 'name: jellyfin' <<< "$jellyfin" \
  || { printf 'FAIL: Jellyfin project name missing\n' >&2; exit 1; }
grep -Fq "Host(\`flix.example.test\`)" <<< "$jellyfin" \
  || { printf 'FAIL: Jellyfin host rule missing\n' >&2; exit 1; }
grep -Fq 'https://flix.example.test' <<< "$jellyfin" \
  || { printf 'FAIL: Jellyfin published URL missing\n' >&2; exit 1; }
grep -Fq 'http://127.0.0.1:8096' <<< "$jellyfin" \
  || { printf 'FAIL: Jellyfin upstream missing\n' >&2; exit 1; }
grep -Fq 'host_ip: 127.0.0.1' <<< "$jellyfin" \
  || { printf 'FAIL: Jellyfin port is not loopback-bound\n' >&2; exit 1; }
grep -Fq "${TMP}/data/jellyfin/config" <<< "$jellyfin" \
  || { printf 'FAIL: Jellyfin config mount missing\n' >&2; exit 1; }

if grep -Fq 'priyav.dev' <<< "$traefik$jellyfin"; then
  printf 'FAIL: production domain leaked into rendered compose\n' >&2
  exit 1
fi

printf 'compose render tests passed\n'
