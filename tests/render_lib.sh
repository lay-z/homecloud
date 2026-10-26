#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

write_root_env() {
  cat > "$TMP/.env" <<EOF
BASE_DOMAIN=example.test
ACME_EMAIL=admin@example.test
DATA_ROOT=$TMP/data
TZ=UTC
PUID=1000
PGID=1000
ENABLED_SERVICES=jellyfin
EOF
}

copy_service() {
  local service="$1"
  cp -a "$ROOT/$service" "$TMP/$service"
  mkdir -p "$TMP/data/$service"
}

install_fixture() {
  local service="$1"
  cp "$ROOT/tests/fixtures/$service.env" "$TMP/$service/.env"
  cp "$ROOT/tests/fixtures/$service.secrets" "$TMP/$service/.secrets"
  chmod 600 "$TMP/$service/.secrets"
}

render_service() {
  local service="$1"
  shift
  local args=(--env-file "$TMP/.env" -f "$TMP/$service/compose.yaml")
  local file

  for file in "$@"; do
    args+=(--env-file "$TMP/$service/$file")
  done

  docker compose "${args[@]}" config
}

render_service_json() {
  local service="$1"
  shift
  local args=(--env-file "$TMP/.env" -f "$TMP/$service/compose.yaml")
  local file

  for file in "$@"; do
    args+=(--env-file "$TMP/$service/$file")
  done

  docker compose "${args[@]}" config --format json
}

assert_render_contains() {
  local rendered="$1"
  local needle="$2"
  local message="$3"

  grep -Fq -- "$needle" <<< "$rendered" || fail "$message"
}

assert_no_volumes() {
  local rendered="$1"

  if grep -Eq '"type"[[:space:]]*:[[:space:]]*"volume"' <<< "$rendered"; then
    fail "rendered compose has a named or anonymous volume"
  fi
}

assert_mount() {
  local rendered="$1"
  local source="$2"
  local target="$3"
  local message="$4"
  local service="${5:-}"

  if ! python3 -c '
import json, sys
data = json.load(sys.stdin)
source, target = sys.argv[1], sys.argv[2]
service = sys.argv[3]
services = data.get("services", {}).values()
if service:
    services = [data.get("services", {}).get(service, {})]
for service_data in services:
    for volume in service_data.get("volumes", []):
        if volume.get("source") == source and volume.get("target") == target:
            raise SystemExit(0)
raise SystemExit(1)
' "$source" "$target" "$service" <<< "$rendered"; then
    fail "$message"
  fi
}

assert_no_service_mount() {
  local rendered="$1"
  local service="$2"
  local source="$3"
  local target="$4"
  local message="$5"

  if python3 -c '
import json, sys
data = json.load(sys.stdin)
service, source, target = sys.argv[1], sys.argv[2], sys.argv[3]
for volume in data.get("services", {}).get(service, {}).get("volumes", []):
    if volume.get("source") == source and volume.get("target") == target:
        raise SystemExit(0)
raise SystemExit(1)
' "$service" "$source" "$target" <<< "$rendered"; then
    fail "$message"
  fi
}

assert_mount_read_only() {
  local rendered="$1"
  local service="$2"
  local source="$3"
  local target="$4"
  local message="$5"

  if ! python3 -c '
import json, sys
data = json.load(sys.stdin)
service, source, target = sys.argv[1], sys.argv[2], sys.argv[3]
for volume in data.get("services", {}).get(service, {}).get("volumes", []):
    if volume.get("source") == source and volume.get("target") == target and volume.get("read_only") is True:
        raise SystemExit(0)
raise SystemExit(1)
' "$service" "$source" "$target" <<< "$rendered"; then
    fail "$message"
  fi
}

assert_service_env() {
  local rendered="$1"
  local service="$2"
  local key="$3"
  local expected="$4"
  local message="$5"

  if ! python3 -c '
import json, sys
data = json.load(sys.stdin)
service, key, expected = sys.argv[1], sys.argv[2], sys.argv[3]
value = data.get("services", {}).get(service, {}).get("environment", {}).get(key)
if value != expected:
    raise SystemExit(1)
' "$service" "$key" "$expected" <<< "$rendered"; then
    fail "$message"
  fi
}

assert_service_env_absent() {
  local rendered="$1"
  local service="$2"
  local key="$3"
  local message="$4"

  if python3 -c '
import json, sys
data = json.load(sys.stdin)
service, key = sys.argv[1], sys.argv[2]
if key in data.get("services", {}).get(service, {}).get("environment", {}):
    raise SystemExit(0)
raise SystemExit(1)
' "$service" "$key" <<< "$rendered"; then
    fail "$message"
  fi
}

assert_papra_provider() {
  local rendered="$1"
  local client_id="$2"
  local client_secret="$3"
  local base_domain="$4"

  if ! python3 -c '
import json, sys
data = json.load(sys.stdin)
provider = json.loads(data["services"]["papra"]["environment"]["AUTH_PROVIDERS_CUSTOMS"])[0]
client_id, client_secret, base_domain = sys.argv[1], sys.argv[2], sys.argv[3]
expected = {
    "providerId": "authentik",
    "providerName": "authentik",
    "providerIconUrl": f"https://id.{base_domain}/static/dist/assets/icons/icon.png",
    "clientId": client_id,
    "clientSecret": client_secret,
    "type": "oidc",
    "discoveryUrl": f"https://id.{base_domain}/application/o/papra/.well-known/openid-configuration",
    "scopes": ["openid", "profile", "email"],
}
if provider != expected:
    raise SystemExit(1)
' "$client_id" "$client_secret" "$base_domain" <<< "$rendered"; then
    fail "Papra OIDC provider config is wrong"
  fi
}
