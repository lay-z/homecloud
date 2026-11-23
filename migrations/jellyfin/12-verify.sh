#!/usr/bin/env bash
set -euo pipefail

wait_http "http://127.0.0.1:8096/health" 60 3

current="$(running_image_tag jellyfin || true)"
[[ "$current" == 12.* ]] || die "jellyfin is running ${current:-unknown}, expected 12.x"

if "${DOCKER_BIN:-docker}" logs jellyfin --since 30m 2>&1 |
  grep -Eqi 'unhandled exception|database is locked|migration failed'; then
  die "Jellyfin logged a migration or database failure; restore $BACKUP_DIR/jellyfin-config.tar.gz before retrying"
fi

info "Jellyfin $current is healthy"
info "required next step: run a full library scan so alternative versions are rebuilt"
