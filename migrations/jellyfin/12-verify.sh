#!/usr/bin/env bash
set -euo pipefail

MIGRATIONS_DIR="${MIGRATIONS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$MIGRATIONS_DIR/lib.sh"

wait_http "http://127.0.0.1:8096/health" 60 3

current="$(running_image_tag jellyfin || true)"
[[ "$current" == 12.* ]] || die "jellyfin is running ${current:-unknown}, expected 12.x"

# Capture the log first: with `set -o pipefail`, a `grep -q` that exits early
# can make `docker logs` die of SIGPIPE and mask the match.
logs="$("${DOCKER_BIN:-docker}" logs jellyfin --since 30m 2>&1 || true)"
if grep -Eqi 'migration failed|failed to migrate|database is locked|database is corrupt' <<< "$logs"; then
  backup_root="${BACKUP_ROOT:-$DATA_ROOT/backups}"
  # The config archive lives in the backup directory of the *migrate* run, not
  # in this verification run's directory.
  migrate_dir="$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d \
    -name '*-jellyfin-12-migrate' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | head -n1 | cut -d' ' -f2- || true)"
  die "Jellyfin logged a migration or database failure; restore ${migrate_dir:-<timestamp>-jellyfin-12-migrate}/jellyfin-config.tar.gz before retrying"
fi

info "Jellyfin $current is healthy"
info "required next step: run a full library scan so alternative versions are rebuilt"
