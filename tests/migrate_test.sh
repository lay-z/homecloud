#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

assert_not_file() {
  [[ ! -e "$1" ]] || fail "unexpected file: $1"
}

repo="$TMP/repo"
make_repo "$repo"
mkdir -p "$repo/tools"
cp "$ROOT/tools/migrate.sh" "$repo/tools/migrate.sh"
cp -R "$ROOT/migrations" "$repo/migrations"

cp "$repo/.env.example" "$repo/.env"
sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$TMP/data|" "$repo/.env"
sed -i "s|^ENABLED_SERVICES=.*|ENABLED_SERVICES=jellyfin|" "$repo/.env"
"$repo/stack" init >/dev/null

manifest="$TMP/migrations"
mkdir -p "$manifest/fake"
cp "$ROOT/migrations/lib.sh" "$manifest/lib.sh"
cat > "$manifest/fake/preflight.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
info "preflight ran with lib.sh loaded"
printf 'preflight\n' >> "$RECORD"
SH
cat > "$manifest/fake/window.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
grep -Fq ' stop' "$DOCKER_LOG" || { printf 'service was not stopped\n' >&2; exit 1; }
mkdir -p "$DATA_ROOT/fixture"
printf 'fixture\n' > "$DATA_ROOT/fixture/file.txt"
backup_path "$DATA_ROOT/fixture/file.txt" fixture
printf 'window\n' >> "$RECORD"
SH
cat > "$manifest/fake/fail.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 1
SH
cat > "$manifest/fake/confirm.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'confirm\n' >> "$RECORD"
SH
chmod +x "$manifest"/fake/*.sh

cat > "$manifest/manifest.tsv" <<'TSV'
# id	service	release	kind	needs_stop	backup	min_free_mb	script	description
fake-confirm	jellyfin	1.0.0	post	no	no	0	fake/confirm.sh	Requires confirmation
fake-pre	jellyfin	1.0.0	preflight	no	no	0	fake/preflight.sh	Read only check
fake-window	jellyfin	1.0.0	window	yes	no	0	fake/window.sh	Needs the service stopped
fake-fail	jellyfin	1.0.0	post	no	no	0	fake/fail.sh	Always fails
fake-disabled	immich	1.0.0	preflight	no	no	0	fake/preflight.sh	Service is not enabled
TSV

export MIGRATIONS_DIR="$manifest"
export RECORD="$TMP/record"
: > "$RECORD"

list="$("$repo/stack" migrate list)"
[[ "$list" == *"fake-pre"* ]] || fail "migrate list did not list fake-pre"
[[ "$list" == *"jellyfin"* ]] || fail "migrate list did not list the service"

if "$repo/stack" migrate run does-not-exist --yes >/dev/null 2>&1; then
  fail "migrate accepted an unknown migration"
fi

if BACKUP_ROOT="$TMP/not-mounted/backups" \
  "$repo/stack" migrate run fake-confirm --yes >"$TMP/backup-missing.err" 2>&1; then
  fail "migrate accepted a missing configured BACKUP_ROOT"
fi
assert_contains "$TMP/backup-missing.err" "BACKUP_ROOT must already exist"
assert_not_file "$TMP/not-mounted"

mkdir -p "$TMP/same-filesystem-backups"
if BACKUP_ROOT="$TMP/same-filesystem-backups" \
  "$repo/stack" migrate run fake-confirm --yes >"$TMP/backup-device.err" 2>&1; then
  fail "migrate accepted an explicit BACKUP_ROOT on the DATA_ROOT filesystem"
fi
assert_contains "$TMP/backup-device.err" "different filesystem"

if "$repo/stack" migrate run fake-confirm </dev/null >/dev/null 2>&1; then
  fail "migrate ran without confirmation on a non-interactive stdin"
fi
assert_not_file "$TMP/data/.migrations/fake-confirm"
"$repo/stack" migrate run fake-confirm --yes >/dev/null
assert_file "$TMP/data/.migrations/fake-confirm"
assert_contains "$RECORD" "confirm"

if "$repo/stack" migrate run fake-window --yes >"$TMP/order.err" 2>&1; then
  fail "migrate ran a step before its earlier same-service steps"
fi
assert_contains "$TMP/order.err" "completed first"
if grep -Fq ' stop' "$DOCKER_LOG"; then
  fail "migrate stopped the service before rejecting an out-of-order step"
fi

"$repo/stack" migrate run fake-pre --yes >/dev/null
assert_file "$TMP/data/.migrations/fake-pre"
assert_contains "$RECORD" "preflight"

: > "$DOCKER_LOG"
"$repo/stack" migrate run fake-pre --yes >/dev/null
[[ "$(grep -c preflight "$RECORD")" == "1" ]] || fail "migrate reran a completed migration"

"$repo/stack" migrate run fake-window --yes >/dev/null
assert_file "$TMP/data/.migrations/fake-window"
assert_contains "$RECORD" "window"
assert_contains "$DOCKER_LOG" " stop"
assert_contains "$DOCKER_LOG" " up -d"

bakdir="$(find "$TMP/data/backups" -mindepth 1 -maxdepth 1 -type d -name '*-fake-window' | head -n1)"
assert_file "$bakdir/fixture.tar.gz"
assert_contains "$bakdir/SHA256SUMS" "fixture.tar.gz"
[[ "$(tar -xzOf "$bakdir/fixture.tar.gz" file.txt)" == "fixture" ]] ||
  fail "backup_path produced the wrong archive contents"

if "$repo/stack" migrate run fake-fail --yes >/dev/null 2>&1; then
  fail "migrate recorded a failed migration"
fi
[[ ! -e "$TMP/data/.migrations/fake-fail" ]] || fail "failed migration left a journal entry"

if "$repo/stack" migrate run fake-disabled --yes >/dev/null 2>&1; then
  fail "migrate ran a migration for a disabled service"
fi

if MIGRATE_MIN_FREE_MB=999999999 "$repo/stack" migrate run fake-pre --force --yes >/dev/null 2>&1; then
  fail "migrate ignored the free space preflight"
fi

force_record_before="$(grep -c preflight "$RECORD")"
"$repo/stack" migrate run fake-pre --force --yes >/dev/null
force_record_after="$(grep -c preflight "$RECORD")"
[[ "$force_record_after" -gt "$force_record_before" ]] || fail "--force did not rerun a completed migration"

"$repo/stack" migrate validate >/dev/null
"$repo/stack" migrate plan >/dev/null

printf 'migrate tests passed\n'
