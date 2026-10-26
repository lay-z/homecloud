#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/render_lib.sh"

write_root_env

for service in jellyfin immich tandoor authentik papra checkmate; do
  copy_service "$service"
  install_fixture "$service"
  assert_no_volumes "$(render_service_json "$service" .env .secrets)"
done

copy_service traefik
assert_no_volumes "$(render_service_json traefik)"

printf 'phase 2 data safety tests passed\n'
