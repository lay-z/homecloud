#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

repo="$TMP/repo"
make_repo "$repo"

"$repo/stack" init >/dev/null

assert_file "$repo/.env"
assert_file "$repo/jellyfin/.env"
assert_file "$repo/jellyfin/.secrets"
assert_eq "$(stat -c %a "$repo/jellyfin/.secrets")" "600"
assert_contains "$repo/jellyfin/.secrets" "JELLYFIN_SECRET="

sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$TMP/data|" "$repo/.env"
printf '\n# keep me\n' >> "$repo/.env"

"$repo/stack" init >/dev/null

assert_contains "$repo/.env" "# keep me"
assert_file "$TMP/data/traefik/acme.json"
assert_eq "$(stat -c %a "$TMP/data/traefik/acme.json")" "600"
assert_file "$TMP/data/jellyfin/config"
assert_file "$TMP/data/jellyfin/cache"

printf 'init tests passed\n'
