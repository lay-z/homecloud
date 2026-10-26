#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/render_lib.sh"

write_root_env
copy_service authentik
install_fixture authentik

rendered="$(render_service authentik .env .secrets)"
rendered_json="$(render_service_json authentik .env .secrets)"

assert_render_contains "$rendered" 'name: authentik' 'project name missing'
assert_render_contains "$rendered" "Host(\`id.example.test\`)" 'host rule missing'
assert_render_contains "$rendered" 'http://127.0.0.1:9000' 'upstream missing'
assert_render_contains "$rendered" 'host_ip: 127.0.0.1' 'port is not loopback-bound'
assert_render_contains "$rendered" 'user: root' 'worker user missing'
assert_render_contains "$rendered" "$TMP/data/authentik/database" 'database bind missing'
assert_render_contains "$rendered" "$TMP/data/authentik/media" 'media bind missing'
assert_render_contains "$rendered" "$TMP/data/authentik/certs" 'certs bind missing'
assert_render_contains "$rendered" "$TMP/data/authentik/custom-templates" 'templates bind missing'
assert_no_volumes "$rendered_json"
assert_mount "$rendered_json" "$TMP/data/authentik/database" /var/lib/postgresql/data 'postgresql bind missing or wrong target' postgresql
assert_mount "$rendered_json" "$TMP/data/authentik/media" /media 'server media bind missing or wrong target' server
assert_mount "$rendered_json" "$TMP/data/authentik/media" /media 'worker media bind missing or wrong target' worker
assert_mount "$rendered_json" "$TMP/data/authentik/certs" /certs 'worker certs bind missing or wrong target' worker
assert_mount "$rendered_json" "$TMP/data/authentik/custom-templates" /templates 'server templates bind missing or wrong target' server
assert_mount "$rendered_json" "$TMP/data/authentik/custom-templates" /templates 'worker templates bind missing or wrong target' worker
assert_mount "$rendered_json" /var/run/docker.sock /var/run/docker.sock 'worker docker socket bind missing' worker
assert_no_service_mount "$rendered_json" server /var/run/docker.sock /var/run/docker.sock 'server must not mount the docker socket'
assert_no_service_mount "$rendered_json" postgresql /var/run/docker.sock /var/run/docker.sock 'postgresql must not mount the docker socket'
assert_service_env "$rendered_json" postgresql POSTGRES_PASSWORD test-password 'postgresql password missing'
assert_service_env "$rendered_json" server AUTHENTIK_SECRET_KEY test-secret 'server is not loading AUTHENTIK_SECRET_KEY from .secrets'
assert_service_env "$rendered_json" server AUTHENTIK_POSTGRESQL__PASSWORD test-password 'server is not loading the database password'
assert_service_env "$rendered_json" server AUTHENTIK_POSTGRESQL__HOST postgresql 'server database host missing'
assert_service_env "$rendered_json" server AUTHENTIK_POSTGRESQL__NAME authentik 'server database name missing'
assert_service_env "$rendered_json" server AUTHENTIK_POSTGRESQL__USER authentik 'server database user missing'
assert_service_env "$rendered_json" worker AUTHENTIK_SECRET_KEY test-secret 'worker is not loading AUTHENTIK_SECRET_KEY from .secrets'
assert_service_env "$rendered_json" worker AUTHENTIK_POSTGRESQL__PASSWORD test-password 'worker is not loading the database password'

printf 'authentik render tests passed\n'
