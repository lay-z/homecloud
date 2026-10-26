#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

dest="$TMP/volume-data"

if "$ROOT/tools/migrate-volume.sh" >/dev/null 2>&1; then
  fail "accepted missing arguments"
fi
if "$ROOT/tools/migrate-volume.sh" source relative/path extra >/dev/null 2>&1; then
  fail "accepted extra arguments"
fi
if "$ROOT/tools/migrate-volume.sh" source relative/path >/dev/null 2>&1; then
  fail "accepted a relative destination"
fi

: > "$DOCKER_LOG"
"$ROOT/tools/migrate-volume.sh" source_volume "$dest" >/dev/null
assert_contains "$DOCKER_LOG" "volume inspect source_volume"
assert_contains "$DOCKER_LOG" "ps -q --filter volume=source_volume"
assert_contains "$DOCKER_LOG" "run --rm"
assert_contains "$DOCKER_LOG" "-v source_volume:/from:ro"
assert_contains "$DOCKER_LOG" "-v $dest:/to"
assert_contains "$DOCKER_LOG" "alpine:3.20 sh -c cp -a /from/. /to/"

printf 'keep\n' > "$dest/keep"
if "$ROOT/tools/migrate-volume.sh" source_volume "$dest" >/dev/null 2>&1; then
  fail "copied into a non-empty destination"
fi

hidden="$TMP/volume-data-hidden"
mkdir -p "$hidden"
printf 'keep\n' > "$hidden/.hidden"
if "$ROOT/tools/migrate-volume.sh" source_volume "$hidden" >/dev/null 2>&1; then
  fail "copied into a destination with only hidden files"
fi

if DOCKER_MISSING_VOLUME=missing_volume "$ROOT/tools/migrate-volume.sh" missing_volume "$TMP/missing-data" >/dev/null 2>&1; then
  fail "accepted a missing source volume"
fi
[[ ! -e "$TMP/missing-data" ]] || fail "created the destination before validating the volume"

if DOCKER_BUSY_VOLUME=busy_volume "$ROOT/tools/migrate-volume.sh" busy_volume "$TMP/busy-data" >/dev/null 2>&1; then
  fail "copied from a volume in use by a running container"
fi
[[ ! -e "$TMP/busy-data" ]] || fail "created the destination before checking volume use"

lsbin="$TMP/ls-bin"
mkdir -p "$lsbin"
cat > "$lsbin/ls" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$lsbin/ls"
: > "$DOCKER_LOG"
if PATH="$lsbin:$PATH" "$ROOT/tools/migrate-volume.sh" source_volume "$TMP/ls-fail-data" >/dev/null 2>&1; then
  fail "copied when the destination could not be inspected"
fi
if grep -Fq -- "run --rm" "$DOCKER_LOG"; then
  fail "ran the copy after the destination check failed"
fi

: > "$DOCKER_LOG"
if DOCKER_PS_FAIL=1 "$ROOT/tools/migrate-volume.sh" source_volume "$TMP/ps-fail-data" >/dev/null 2>&1; then
  fail "copied when volume use could not be checked"
fi
if grep -Fq -- "run --rm" "$DOCKER_LOG"; then
  fail "ran the copy after the volume-use check failed"
fi
[[ ! -e "$TMP/ps-fail-data" ]] || fail "created the destination before the volume-use check"

printf 'migrate volume tests passed\n'
