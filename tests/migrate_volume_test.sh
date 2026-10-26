#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

dest="$TMP/volume-data"

if "$ROOT/tools/migrate-volume.sh" >/dev/null 2>&1; then
  fail "accepted missing arguments"
fi
if "$ROOT/tools/migrate-volume.sh" source relative/path >/dev/null 2>&1; then
  fail "accepted a relative destination"
fi

: > "$DOCKER_LOG"
"$ROOT/tools/migrate-volume.sh" source_volume "$dest" >/dev/null
assert_contains "$DOCKER_LOG" "run --rm"
assert_contains "$DOCKER_LOG" "-v source_volume:/from:ro"
assert_contains "$DOCKER_LOG" "-v $dest:/to"
assert_contains "$DOCKER_LOG" "alpine:3.20 sh -c cp -a /from/. /to/"

printf 'keep\n' > "$dest/keep"
if "$ROOT/tools/migrate-volume.sh" source_volume "$dest" >/dev/null 2>&1; then
  fail "copied into a non-empty destination"
fi

printf 'migrate volume tests passed\n'
