#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/render_lib.sh"

write_root_env
copy_service papra
install_fixture papra

rendered="$(render_service papra .env .secrets)"
rendered_json="$(render_service_json papra .env .secrets)"

assert_render_contains "$rendered" 'name: papra' 'project name missing'
assert_render_contains "$rendered" "Host(\`docs.example.test\`)" 'host rule missing'
assert_render_contains "$rendered" 'http://127.0.0.1:1221' 'upstream missing'
assert_render_contains "$rendered" 'host_ip: 127.0.0.1' 'port is not loopback-bound'
assert_render_contains "$rendered" "$TMP/data/papra/app-data" 'app-data bind missing'
assert_render_contains "$rendered" 'providerId' 'OIDC provider config missing'
assert_render_contains "$rendered" 'id.example.test/application/o/papra' 'OIDC discovery URL missing'
assert_render_contains "$rendered" 'test-client-id' 'OIDC client id missing'
assert_render_contains "$rendered" 'test-client-secret' 'OIDC client secret missing'
assert_no_volumes "$rendered_json"
assert_mount "$rendered_json" "$TMP/data/papra/app-data" /app/app-data 'app-data bind missing or wrong target' papra
assert_service_env "$rendered_json" papra APP_BASE_URL https://docs.example.test 'app base URL missing'
assert_service_env "$rendered_json" papra AUTH_PROVIDERS_EMAIL_IS_ENABLED false 'email auth setting missing'
assert_service_env "$rendered_json" papra AUTH_SECRET test-secret 'auth secret missing'
assert_service_env "$rendered_json" papra PAPRA_OIDC_CLIENT_ID test-client-id 'OIDC client id not loaded'
assert_service_env "$rendered_json" papra PAPRA_OIDC_CLIENT_SECRET test-client-secret 'OIDC client secret not loaded'
assert_papra_provider "$rendered_json" test-client-id test-client-secret example.test

if grep -Fq 'priyav.dev' <<< "$rendered"; then
  fail "production domain leaked into rendered compose"
fi

printf 'papra render tests passed\n'
