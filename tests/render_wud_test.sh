#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/render_lib.sh"

write_root_env
copy_service wud
install_fixture wud

rendered="$(render_service wud .env .secrets)"
rendered_json="$(render_service_json wud .env .secrets)"

assert_render_contains "$rendered" 'name: wud' 'project name missing'
assert_render_contains "$rendered" "Host(\`wud.example.test\`)" 'host rule missing'
assert_render_contains "$rendered" 'http://127.0.0.1:3000' 'upstream missing'
assert_render_contains "$rendered" 'host_ip: 127.0.0.1' 'port is not loopback-bound'
assert_render_contains "$rendered" "$TMP/data/wud/store" 'store bind missing'
assert_no_volumes "$rendered_json"
assert_mount "$rendered_json" "$TMP/data/wud/store" /store 'store bind missing or wrong target' wud
assert_mount_read_only "$rendered_json" wud /var/run/docker.sock /var/run/docker.sock 'docker socket must be read-only'

assert_service_env "$rendered_json" wud WUD_PUBLIC_URL https://wud.example.test 'public url missing'
assert_service_env "$rendered_json" wud WUD_AUTH_OIDC_AUTHENTIK_CLIENTID test-wud-client-id 'OIDC client id not injected'
assert_service_env "$rendered_json" wud WUD_AUTH_OIDC_AUTHENTIK_CLIENTSECRET test-wud-client-secret 'OIDC client secret not injected'
assert_service_env "$rendered_json" wud WUD_AUTH_OIDC_AUTHENTIK_DISCOVERY "https://id.example.test/application/o/wud/.well-known/openid-configuration" 'OIDC discovery URL missing'
assert_service_env "$rendered_json" wud WUD_AUTH_OIDC_AUTHENTIK_ADMINGROUP 'authentik Admins' 'OIDC admin group mapping missing'
assert_service_env "$rendered_json" wud WUD_AUTH_OIDC_AUTHENTIK_DEFAULTROLE none 'non-admin users must be denied'
assert_service_env "$rendered_json" wud WUD_TRIGGER_TELEGRAM_NOTIFY_BOTTOKEN '123456:test-token' 'telegram bot token missing'
assert_service_env "$rendered_json" wud WUD_TRIGGER_TELEGRAM_NOTIFY_CHATID 12345678 'telegram chat id missing'
assert_service_env "$rendered_json" wud WUD_TRIGGER_TELEGRAM_NOTIFY_MODE batch 'telegram batch mode missing'
assert_service_env "$rendered_json" wud WUD_AUTH_SESSION_SECRET 0123456789abcdef0123456789abcdef 'session secret missing'

if grep -Fq 'forwardauth' <<< "$rendered"; then
  fail "wud must use native OIDC, not Traefik forward auth"
fi

if grep -Fq 'priyav.dev' <<< "$rendered"; then
  fail "production domain leaked into rendered compose"
fi

blueprint="$ROOT/authentik/blueprints/wud.yaml"
[[ -f "$blueprint" ]] || fail "authentik blueprint missing"
for needle in \
  'version: 1' \
  'authentik_providers_oauth2.oauth2provider' \
  'authentik_core.application' \
  'authentik_policies.policybinding' \
  '/auth/oidc/authentik/cb' \
  'scope-profile'; do
  grep -Fq -- "$needle" "$blueprint" || fail "blueprint does not contain: $needle"
done

if grep -Eq 'wud\.[a-z0-9.-]+\.(dev|com|test)' "$blueprint"; then
  fail "blueprint hardcodes a domain"
fi

printf 'wud render tests passed\n'
