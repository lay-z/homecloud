#!/usr/bin/env bash
set -euo pipefail

current="$(running_image_tag jellyfin || true)"
[[ -n "$current" ]] || die "could not read the running Jellyfin version"
info "jellyfin $current -> $RELEASE"

if [[ "$current" == 12.* ]]; then
  info "already running $current"
  exit 0
fi
[[ "$current" == 10.11.* ]] ||
  die "Jellyfin 12 supports direct upgrades from 10.10.7 and 10.11.x only (running $current)"

assert_compose_image 'jellyfin/jellyfin:12.'

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
    die "remove third-party plugins before upgrading to Jellyfin 12"
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

info "config size: $(du -sh "$DATA_ROOT/jellyfin/config" | cut -f1)"
info "preflight passed"
