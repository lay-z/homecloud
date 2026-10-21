#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

repo="$TMP/repo"
make_repo "$repo"
cp "$repo/.env.example" "$repo/.env"
sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$TMP/data|" "$repo/.env"
"$repo/stack" init >/dev/null

: > "$DOCKER_LOG"
"$repo/stack" up >/dev/null

mapfile -t ups < <(grep ' up -d' "$DOCKER_LOG")
[[ "${#ups[@]}" -ge 2 ]] || fail "expected Traefik and Jellyfin up calls"
[[ "${ups[0]}" == *"traefik/compose.yaml"* ]] || fail "Traefik was not started first"
[[ "${ups[1]}" == *"jellyfin/compose.yaml"* ]] || fail "Jellyfin was not started second"

printf 'services:\n' > "$repo/jellyfin/compose.override.yaml"
: > "$DOCKER_LOG"
"$repo/stack" up >/dev/null
assert_contains "$DOCKER_LOG" "jellyfin/compose.override.yaml"

if "$repo/stack" down -v >/dev/null 2>&1; then
  fail "down accepted -v"
fi

rm "$repo/jellyfin/compose.override.yaml"

: > "$DOCKER_LOG"
"$repo/stack" down >/dev/null
assert_contains "$DOCKER_LOG" "jellyfin/compose.yaml down"
assert_contains "$DOCKER_LOG" "traefik/compose.yaml down"
if grep -q -- ' -v' "$DOCKER_LOG"; then
  fail "down used -v"
fi

printf 'lifecycle tests passed\n'
