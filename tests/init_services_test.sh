#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

repo="$TMP/repo"
make_repo "$repo"

for svc in immich tandoor authentik papra checkmate; do
  mkdir -p "$repo/$svc"
  printf 'SERVICE_VALUE=test\n' > "$repo/$svc/.env.example"
  if [[ "$svc" == checkmate ]]; then
    printf 'JWT_SECRET=\nENCRYPTION_KEY=\n' > "$repo/$svc/.secrets.example"
  else
    printf 'SERVICE_SECRET=\n' > "$repo/$svc/.secrets.example"
  fi
done

cp "$repo/.env.example" "$repo/.env"
sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$TMP/data|" "$repo/.env"
sed -i "s|^ENABLED_SERVICES=.*|ENABLED_SERVICES=jellyfin,immich,tandoor,authentik,papra,checkmate|" "$repo/.env"

"$repo/stack" init >/dev/null

for dir in \
  jellyfin/config jellyfin/cache \
  immich/postgres immich/model-cache immich/redis \
  tandoor/postgresql tandoor/staticfiles tandoor/mediafiles \
  authentik/database authentik/media authentik/certs authentik/custom-templates \
  papra/app-data \
  checkmate/mongo-data checkmate/mongo-configdb; do
  assert_dir "$TMP/data/$dir"
done

jwt_secret="$(sed -n 's/^JWT_SECRET=//p' "$repo/checkmate/.secrets")"
[[ "$jwt_secret" =~ ^[0-9a-f]{64}$ ]] || fail "JWT_SECRET is not 32 bytes of hex"

encryption_key="$(sed -n 's/^ENCRYPTION_KEY=//p' "$repo/checkmate/.secrets")"
[[ "$encryption_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "ENCRYPTION_KEY is not 32 bytes of base64"

printf 'init service tests passed\n'
