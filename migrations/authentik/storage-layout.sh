#!/usr/bin/env bash
set -euo pipefail

src="$DATA_ROOT/authentik/media"
dst="$DATA_ROOT/authentik/data/media"

compose_config_has 'authentik/data:/data'

if [[ -d "$dst" ]]; then
  info "already using $dst"
  exit 0
fi

if [[ ! -d "$src" ]]; then
  warn "$src does not exist; creating $dst for a fresh install"
  mkdir -p "$dst"
  exit 0
fi

backup_path "$src" authentik-media

mkdir -p "$(dirname "$dst")"
mv "$src" "$dst"
[[ -d "$dst" ]] || die "move failed: $dst is missing"
[[ ! -e "$src" ]] || die "move left $src behind"

info "moved $src -> $dst"
info "authentik 2025.12 now stores files under /data; the /files URL prefix replaces /media"
