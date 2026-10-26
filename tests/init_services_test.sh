#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

repo="$TMP/repo"
make_repo "$repo"

for svc in immich tandoor authentik papra checkmate; do
  mkdir -p "$repo/$svc"
  printf 'SERVICE_VALUE=test\n' > "$repo/$svc/.env.example"
  printf 'SERVICE_SECRET=\n' > "$repo/$svc/.secrets.example"
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

printf 'init service tests passed\n'
