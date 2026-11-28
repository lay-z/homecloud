#!/usr/bin/env bash
set -euo pipefail

MIGRATIONS_DIR="${MIGRATIONS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$MIGRATIONS_DIR/lib.sh"

src="$DATA_ROOT/authentik/media"
dst="$DATA_ROOT/authentik/data/media"

compose_service_config_has server 'authentik/data:/data'
compose_service_config_has worker 'authentik/data:/data'

if [[ -e "$dst" && ! -d "$dst" ]]; then
  die "$dst exists but is not a directory"
fi

if [[ ! -d "$src" ]]; then
  if [[ -d "$dst" ]]; then
    info "already using $dst"
    exit 0
  fi
  warn "$src does not exist; creating $dst for a fresh install"
  mkdir -p "$dst"
  exit 0
fi

backup_path "$src" authentik-media

if [[ -d "$dst" ]]; then
  if [[ -n "$(find "$dst" -mindepth 1 -print -quit)" ]]; then
    die "both $src and $dst contain files; the source is backed up, but merge the directories safely before retrying"
  fi
  rmdir "$dst"
fi

mkdir -p "$(dirname "$dst")"
mv "$src" "$dst"
[[ -d "$dst" ]] || die "move failed: $dst is missing"
[[ ! -e "$src" ]] || die "move left $src behind"

info "moved $src -> $dst"
info "authentik 2025.12 now stores files under /data; the /files URL prefix replaces /media"
