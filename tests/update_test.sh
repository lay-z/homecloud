#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

repo="$TMP/repo"
make_repo "$repo"
cp "$repo/.env.example" "$repo/.env"
sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$TMP/data|" "$repo/.env"
"$repo/stack" init >/dev/null

git -C "$repo" init -q
git -C "$repo" config user.email "test@example.test"
git -C "$repo" config user.name "Test"
git -C "$repo" add -A
git -C "$repo" commit -qm "initial"
git -C "$repo" tag v0.1.0

git init --bare -q "$TMP/remote.git"
git -C "$repo" remote add origin "$TMP/remote.git"
git -C "$repo" push -qu origin HEAD --tags

printf '\n# dirty\n' >> "$repo/stack"
if "$repo/stack" update >/dev/null 2>&1; then
  fail "update accepted a dirty tracked tree"
fi
git -C "$repo" checkout -- stack

: > "$DOCKER_LOG"
"$repo/stack" update >/dev/null
assert_contains "$DOCKER_LOG" "traefik/compose.yaml up -d"

printf 'JELLYFIN_SECRET=supersecret\n' >> "$repo/jellyfin/.secrets"
doctor="$("$repo/stack" doctor)"
[[ "$doctor" != *"supersecret"* ]] || fail "doctor leaked a secret value"
[[ "$doctor" == *"JELLYFIN_SECRET"* ]] || fail "doctor did not list secret keys"

printf 'update tests passed\n'
