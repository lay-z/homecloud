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

printf 'compose render tests passed\n'
