#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/render_lib.sh"

write_root_env
copy_service immich
install_fixture immich

rendered="$(render_service immich .env .secrets)"

assert_render_contains "$rendered" 'name: immich' 'project name missing'
assert_render_contains "$rendered" "Host(\`photos.example.test\`)" 'host rule missing'
assert_render_contains "$rendered" 'http://127.0.0.1:2283' 'upstream missing'
assert_render_contains "$rendered" 'host_ip: 127.0.0.1' 'port is not loopback-bound'
assert_render_contains "$rendered" "$TMP/data/immich/postgres" 'postgres bind missing'
assert_render_contains "$rendered" "$TMP/data/immich/model-cache" 'model cache bind missing'
assert_render_contains "$rendered" "$TMP/data/immich/redis" 'redis bind missing'
assert_no_volumes "$(render_service_json immich .env .secrets)"

printf 'immich render tests passed\n'
