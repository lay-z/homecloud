#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

repo="$TMP/repo"
make_repo "$repo"
cp "$repo/.env.example" "$repo/.env"
sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$TMP/data|" "$repo/.env"
"$repo/stack" init >/dev/null

"$repo/stack" check >/dev/null

cp "$repo/.env" "$repo/.env.good"
sed -i 's|^BASE_DOMAIN=.*|BASE_DOMAIN=https://bad|' "$repo/.env"
if "$repo/stack" check >/dev/null 2>&1; then
  fail "check accepted a base domain with a scheme"
fi
mv "$repo/.env.good" "$repo/.env"

mv "$repo/jellyfin/.env" "$repo/jellyfin/.env.bak"
if "$repo/stack" check >/dev/null 2>&1; then
  fail "check accepted a missing service .env"
fi
mv "$repo/jellyfin/.env.bak" "$repo/jellyfin/.env"

mv "$repo/jellyfin/.secrets" "$repo/jellyfin/.secrets.bak"
if "$repo/stack" check >/dev/null 2>&1; then
  fail "check accepted a missing service .secrets"
fi
mv "$repo/jellyfin/.secrets.bak" "$repo/jellyfin/.secrets"

printf '\nBASE_DOMAIN=bad.example\n' >> "$repo/jellyfin/.env"
if "$repo/stack" check >/dev/null 2>&1; then
  fail "check accepted a reserved key in a service env"
fi
sed -i '/^BASE_DOMAIN=bad.example$/d' "$repo/jellyfin/.env"

if DOCKER_VOLUME_JSON=1 "$repo/stack" check >/dev/null 2>&1; then
  fail "check accepted a named volume"
fi

: > "$DOCKER_LOG"
"$repo/stack" check >/dev/null

assert_contains "$DOCKER_LOG" "--env-file $repo/.env"
assert_contains "$DOCKER_LOG" "--env-file $repo/jellyfin/.env"
assert_contains "$DOCKER_LOG" "--env-file $repo/jellyfin/.secrets"
assert_contains "$DOCKER_LOG" "jellyfin/compose.yaml config -q"
assert_contains "$DOCKER_LOG" "traefik/compose.yaml config -q"

mkdir -p "$repo/checkmate" "$TMP/data/checkmate"
printf 'name: checkmate\nservices:\n  checkmate:\n    image: checkmate\n' > "$repo/checkmate/compose.yaml"
printf 'ENCRYPTION_KEY=\n' > "$repo/checkmate/.secrets.example"
: > "$repo/checkmate/.env"
printf 'ENCRYPTION_KEY=not-base64\n' > "$repo/checkmate/.secrets"
chmod 600 "$repo/checkmate/.secrets"
sed -i 's|^ENABLED_SERVICES=.*|ENABLED_SERVICES=jellyfin,checkmate|' "$repo/.env"

if "$repo/stack" check >/dev/null 2>&1; then
  fail "check accepted an invalid ENCRYPTION_KEY"
fi

printf 'ENCRYPTION_KEY=Y2hlY2ttYXRlLXRlc3QtZW5jcnlwdGlvbi1rZXktMzI=\n' > "$repo/checkmate/.secrets"
"$repo/stack" check >/dev/null

printf 'check tests passed\n'
