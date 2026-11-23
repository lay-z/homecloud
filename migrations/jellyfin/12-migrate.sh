#!/usr/bin/env bash
set -euo pipefail

assert_compose_image 'jellyfin/jellyfin:12.'

config="$DATA_ROOT/jellyfin/config"
backup_path "$config" jellyfin-config

info "running the Jellyfin 12 system migration without serving requests"
compose_svc run --rm --no-deps jellyfin --mode MigrateSystem

info "offline migration finished; the runner restarts Jellyfin on 12.4"
