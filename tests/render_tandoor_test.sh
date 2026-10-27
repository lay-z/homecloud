#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/render_lib.sh"

write_root_env
copy_service tandoor
install_fixture tandoor

rendered="$(render_service tandoor .env .secrets)"
rendered_json="$(render_service_json tandoor .env .secrets)"

assert_render_contains "$rendered" 'name: tandoor' 'project name missing'
assert_render_contains "$rendered" "Host(\`recipes.example.test\`)" 'host rule missing'
assert_render_contains "$rendered" 'http://127.0.0.1:8979' 'upstream missing'
assert_render_contains "$rendered" 'host_ip: 127.0.0.1' 'port is not loopback-bound'
assert_render_contains "$rendered" "$TMP/data/tandoor/postgresql" 'postgres bind missing'
assert_render_contains "$rendered" "$TMP/data/tandoor/staticfiles" 'staticfiles bind missing'
assert_render_contains "$rendered" "$TMP/data/tandoor/mediafiles" 'mediafiles bind missing'
assert_render_contains "$rendered" 'ALLOWED_HOSTS: recipes.example.test' 'allowed hosts missing'
assert_no_volumes "$rendered_json"
assert_mount "$rendered_json" "$TMP/data/tandoor/postgresql" /var/lib/postgresql/data 'postgres bind missing or wrong target'
assert_mount "$rendered_json" "$TMP/data/tandoor/staticfiles" /opt/recipes/staticfiles 'staticfiles bind missing or wrong target'
assert_mount "$rendered_json" "$TMP/data/tandoor/mediafiles" /opt/recipes/mediafiles 'mediafiles bind missing or wrong target'
assert_service_env "$rendered_json" web_recipes SECRET_KEY test-secret 'web_recipes is not loading SECRET_KEY from .secrets'
assert_service_env "$rendered_json" web_recipes POSTGRES_PASSWORD test-password 'web_recipes is not loading POSTGRES_PASSWORD from .secrets'
assert_service_env "$rendered_json" db_recipes POSTGRES_PASSWORD test-password 'db_recipes is not loading POSTGRES_PASSWORD from .secrets'
assert_service_env_absent "$rendered_json" db_recipes SECRET_KEY 'db_recipes must not receive SECRET_KEY'
assert_service_env_absent "$rendered_json" db_recipes EMAIL_HOST_PASSWORD 'db_recipes must not receive EMAIL_HOST_PASSWORD'

printf 'tandoor render tests passed\n'
