#!/usr/bin/env bash
set -euo pipefail

MIGRATIONS_DIR="${MIGRATIONS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$MIGRATIONS_DIR/lib.sh"

current="$(running_image_tag jellyfin || true)"

if [[ -z "$current" ]]; then
  warn "jellyfin is not running; reading the compose pin instead"
  current="$(compose_svc config --images | grep -F 'jellyfin/jellyfin:' | head -n1 || true)"
  current="${current%%@*}"
  current="${current##*:}"
fi

[[ -n "$current" ]] || die "could not determine the Jellyfin version"
info "jellyfin $current -> $RELEASE"

# Run this check before deploying 12: the supported source version, plugins,
# and usernames must be verified before the target image can touch the data.
if [[ "$current" == 10.11.* || "$current" == 10.10.7* ]]; then
  info "direct upgrade from $current is supported"
else
  die "run this preflight while Jellyfin 10.10.7 or 10.11.x is still serving, before deploying 12 (running $current)"
fi

plugins_dir="$DATA_ROOT/jellyfin/config/plugins"
mapfile -t plugins < <(
  find "$plugins_dir" -mindepth 1 -maxdepth 1 -type d ! -name configurations -printf '%f\n' 2>/dev/null | sort
)

if (( ${#plugins[@]} > 0 )); then
  if [[ "${JELLYFIN_ALLOW_PLUGINS:-0}" == "1" ]]; then
    warn "continuing with installed plugins: ${plugins[*]}"
  else
    printf 'Installed third-party plugins:\n' >&2
    printf '  %s\n' "${plugins[@]}" >&2
    cat >&2 <<EOF

Jellyfin 12 changes the database in ways plugins are not expected to survive.
Move the plugin directories aside, then rerun this preflight:

  mkdir -p "\$DATA_ROOT/jellyfin/plugins-pre-12"
  mv "\$DATA_ROOT/jellyfin/config/plugins/"*/ "\$DATA_ROOT/jellyfin/plugins-pre-12/"

Reinstall plugin versions built for 12.0 after the upgrade. Set
JELLYFIN_ALLOW_PLUGINS=1 only if you accept the risk of a failed migration.
EOF
    die "remove third-party plugins before running the Jellyfin 12 migration"
  fi
fi

db="$DATA_ROOT/jellyfin/config/data/jellyfin.db"
if [[ -f "$db" ]]; then
  if command -v sqlite3 >/dev/null 2>&1; then
    collisions="$(sqlite3 "file:$db?mode=ro" \
      "select Username from Users group by lower(Username) having count(*) > 1;" 2>/dev/null || true)"
    if [[ -n "$collisions" ]]; then
      printf 'usernames differing only by case:\n%s\n' "$collisions" >&2
      die "Jellyfin 12 adds a unique index on normalized usernames; rename these users first"
    fi
    info "no case-colliding usernames"
  else
    warn "sqlite3 is not installed; skipping the username collision check"
  fi
else
  warn "$db not found; treating this as a fresh install"
fi

info "config size: $(du -sh "$DATA_ROOT/jellyfin/config" 2>/dev/null | cut -f1)"
info "preflight passed"
