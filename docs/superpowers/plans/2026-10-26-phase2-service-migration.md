# Phase 2 Service Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert Immich, Tandoor, Authentik, Papra, and Checkmate to the per-service repo pattern, including the named-volume to bind-mount moves, without cutting production ingress over from nginx.

**Architecture:** Each service becomes a top-level directory with `compose.yaml`, `.env.example`, and `.secrets.example`. All persistent paths become bind mounts under `${DATA_ROOT}/<service>`; large media stays at its existing host path via a service env value. A small migration tool copies existing named volumes into bind paths. nginx keeps owning 80/443 until Phase 3.

**Tech Stack:** Bash, Docker Compose v2, Traefik v3, Immich, Tandoor, Authentik, Papra, Checkmate, MongoDB, PostgreSQL, GitHub Actions.

---

## Current phase and scope

Phase 1 converted Jellyfin and added the foundation. This plan is Phase 2: convert the remaining public services and prepare their data moves. Phase 3 cuts ingress from nginx to Traefik and adds the update timer.

In scope:

- Convert Immich, Tandoor, Authentik, Papra, and Checkmate into per-service directories.
- Pin every image currently running on the server.
- Convert every named and anonymous data volume to a bind mount under `${DATA_ROOT}/<service>`.
- Add a tested volume-migration tool for the existing named volumes.
- Extend `stack init` for the new data directories.
- Add per-service render tests, a consolidated data-safety test, and CI coverage.
- Document the exact server move and soft-swap procedure for each service.

Out of scope:

- Stopping nginx, changing DNS, or cutting 80/443 over to Traefik. That is Phase 3.
- Migrating `/mnt/seagate/Media/Photos` (Immich uploads) or `/mnt/seagate` (Jellyfin media). Both are already large bind mounts outside the repo and stay where they are.
- The `assets.priyav.dev` host. Its Snipe-IT containers are not running; decide its fate in Phase 3.
- Sonarr, openclaw, and other non-public services.

## Observed server state

The plan below was written against this running state (`ssh homeserver`):

| Service | Container path | Current mount | Target |
| --- | --- | --- | --- |
| Jellyfin | `/config`, `/cache` | bind `/home/layz/jellyfin/*` | already correct |
| Jellyfin | `/media` | bind `/mnt/seagate` | keep via `JELLYFIN_MEDIA_PATH` |
| Immich | `/data` | bind `/mnt/seagate/Media/Photos` | keep via `IMMICH_UPLOAD_LOCATION` |
| Immich | `/var/lib/postgresql/data` | bind `/home/layz/immich/postgres` | `${DATA_ROOT}/immich/postgres` |
| Immich | `/cache` | volume `immich_model-cache` (824 MB) | `${DATA_ROOT}/immich/model-cache` |
| Immich | `/data` (redis) | anonymous volume (9 MB) | `${DATA_ROOT}/immich/redis` |
| Tandoor | `/var/lib/postgresql/data` | bind `/home/layz/tandoor/postgresql` | `${DATA_ROOT}/tandoor/postgresql` |
| Tandoor | `/opt/recipes/mediafiles` | bind `/home/layz/tandoor/mediafiles` | `${DATA_ROOT}/tandoor/mediafiles` |
| Tandoor | `/opt/recipes/staticfiles` | volume `tandoor_staticfiles` (90 MB) | `${DATA_ROOT}/tandoor/staticfiles` |
| Authentik | `/var/lib/postgresql/data` | volume `authentik_database` (249 MB) | `${DATA_ROOT}/authentik/database` |
| Authentik | `/media`, `/certs`, `/templates` | bind `/home/layz/authentik/*` | `${DATA_ROOT}/authentik/*` |
| Papra | `/app/app-data` | bind `/home/layz/papra/app-data` | `${DATA_ROOT}/papra/app-data` |
| Checkmate | `/data/db` | volume `checkmate_mongo-data` (439 MB) | `${DATA_ROOT}/checkmate/mongo-data` |
| Checkmate | `/data/configdb` | anonymous volume (0 B) | `${DATA_ROOT}/checkmate/mongo-configdb` |

`DATA_ROOT=/home/layz` on the reference server, so the target paths match the live Jellyfin, Tandoor, Authentik, and Papra binds. Immich's Postgres already matches. Only the four named/anonymous volumes need a data copy.

## File structure

```text
.
├── tools/
│   ├── dns/
│   └── migrate-volume.sh
├── immich/
│   ├── compose.yaml
│   ├── .env.example
│   └── .secrets.example
├── tandoor/
│   ├── compose.yaml
│   ├── .env.example
│   └── .secrets.example
├── authentik/
│   ├── compose.yaml
│   ├── .env.example
│   └── .secrets.example
├── papra/
│   ├── compose.yaml
│   ├── .env.example
│   └── .secrets.example
├── checkmate/
│   ├── compose.yaml
│   ├── compose.override.yaml.example
│   ├── .env.example
│   └── .secrets.example
├── tests/
│   ├── render_lib.sh
│   ├── fixtures/
│   │   ├── jellyfin.env
│   │   ├── jellyfin.secrets
│   │   ├── immich.env
│   │   ├── immich.secrets
│   │   ├── tandoor.env
│   │   ├── tandoor.secrets
│   │   ├── authentik.env
│   │   ├── authentik.secrets
│   │   ├── papra.env
│   │   ├── papra.secrets
│   │   ├── checkmate.env
│   │   └── checkmate.secrets
│   ├── init_services_test.sh
│   ├── migrate_volume_test.sh
│   ├── render_immich_test.sh
│   ├── render_tandoor_test.sh
│   ├── render_authentik_test.sh
│   ├── render_papra_test.sh
│   ├── render_checkmate_test.sh
│   └── data_safety_phase2_test.sh
├── stack                       # modified: init data directories
├── .github/workflows/ci.yml    # modified: run new tests
├── README.md                   # modified: service status
├── docs/operations.md          # modified: volume moves
├── docs/adopt-existing-server.md  # modified: exact move and swap runbook
└── AGENTS.md                   # modified: current phase
```

Responsibilities:

- `tools/migrate-volume.sh`: copy one named volume into an empty absolute path; refuses non-empty destinations.
- `<service>/compose.yaml`: one stack, explicit `name:`, pinned image, loopback port, Traefik labels, bind mounts only.
- `<service>/.env` / `.secrets`: service-local values; secrets only in `.secrets`.
- `tests/render_lib.sh`: shared fixtures and compose rendering for the new tests.
- `tests/fixtures/*.env` / `*.secrets`: dummy values safe to commit; never real credentials.

---

### Task 1: Add the volume migration tool

**Files:**
- Create: `tools/migrate-volume.sh`
- Create: `tests/migrate_volume_test.sh`
- Modify: `tests/lib.sh`

- [ ] **Step 1: Write the failing test**

Extend the fake docker in `tests/lib.sh`. In the heredoc that writes `$TMP/bin/docker`, add these cases after the existing `DOCKER_VOLUME_JSON` block and before `exit 0`:

```bash
if [[ "${DOCKER_PS_FAIL:-0}" == "1" && "$*" == *"ps -q"* ]]; then
  exit 1
fi
if [[ -n "${DOCKER_MISSING_VOLUME:-}" && "$*" == "volume inspect $DOCKER_MISSING_VOLUME" ]]; then
  exit 1
fi
if [[ -n "${DOCKER_BUSY_VOLUME:-}" && "$*" == "ps -q --filter volume=$DOCKER_BUSY_VOLUME" ]]; then
  printf 'fake-container-id\n'
  exit 0
fi
```

Create `tests/migrate_volume_test.sh` with exactly:

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

dest="$TMP/volume-data"

if "$ROOT/tools/migrate-volume.sh" >/dev/null 2>&1; then
  fail "accepted missing arguments"
fi
if "$ROOT/tools/migrate-volume.sh" source relative/path extra >/dev/null 2>&1; then
  fail "accepted extra arguments"
fi
if "$ROOT/tools/migrate-volume.sh" source relative/path >/dev/null 2>&1; then
  fail "accepted a relative destination"
fi

: > "$DOCKER_LOG"
"$ROOT/tools/migrate-volume.sh" source_volume "$dest" >/dev/null
assert_contains "$DOCKER_LOG" "volume inspect source_volume"
assert_contains "$DOCKER_LOG" "ps -q --filter volume=source_volume"
assert_contains "$DOCKER_LOG" "run --rm"
assert_contains "$DOCKER_LOG" "-v source_volume:/from:ro"
assert_contains "$DOCKER_LOG" "-v $dest:/to"
assert_contains "$DOCKER_LOG" "alpine:3.20 sh -c cp -a /from/. /to/"

printf 'keep\n' > "$dest/keep"
: > "$DOCKER_LOG"
if "$ROOT/tools/migrate-volume.sh" source_volume "$dest" >/dev/null 2>&1; then
  fail "copied into a non-empty destination"
fi
if grep -Fq -- "run --rm" "$DOCKER_LOG"; then
  fail "ran the copy into a non-empty destination"
fi

hidden="$TMP/volume-data-hidden"
mkdir -p "$hidden"
printf 'keep\n' > "$hidden/.hidden"
: > "$DOCKER_LOG"
if "$ROOT/tools/migrate-volume.sh" source_volume "$hidden" >/dev/null 2>&1; then
  fail "copied into a destination with only hidden files"
fi
if grep -Fq -- "run --rm" "$DOCKER_LOG"; then
  fail "ran the copy into a destination with only hidden files"
fi

if DOCKER_MISSING_VOLUME=missing_volume "$ROOT/tools/migrate-volume.sh" missing_volume "$TMP/missing-data" >/dev/null 2>&1; then
  fail "accepted a missing source volume"
fi
[[ ! -e "$TMP/missing-data" ]] || fail "created the destination before validating the volume"

if DOCKER_BUSY_VOLUME=busy_volume "$ROOT/tools/migrate-volume.sh" busy_volume "$TMP/busy-data" >/dev/null 2>&1; then
  fail "copied from a volume in use by a running container"
fi
[[ ! -e "$TMP/busy-data" ]] || fail "created the destination before checking volume use"

lsbin="$TMP/ls-bin"
mkdir -p "$lsbin"
cat > "$lsbin/ls" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$lsbin/ls"
: > "$DOCKER_LOG"
if PATH="$lsbin:$PATH" "$ROOT/tools/migrate-volume.sh" source_volume "$TMP/ls-fail-data" >/dev/null 2>&1; then
  fail "copied when the destination could not be inspected"
fi
if grep -Fq -- "run --rm" "$DOCKER_LOG"; then
  fail "ran the copy after the destination check failed"
fi

: > "$DOCKER_LOG"
if DOCKER_PS_FAIL=1 "$ROOT/tools/migrate-volume.sh" source_volume "$TMP/ps-fail-data" >/dev/null 2>&1; then
  fail "copied when volume use could not be checked"
fi
if grep -Fq -- "run --rm" "$DOCKER_LOG"; then
  fail "ran the copy after the volume-use check failed"
fi
[[ ! -e "$TMP/ps-fail-data" ]] || fail "created the destination before the volume-use check"

printf 'migrate volume tests passed\n'
```

- [ ] **Step 2: Run it to verify failure**

```bash
chmod +x tests/migrate_volume_test.sh
./tests/migrate_volume_test.sh
```

Expected: FAIL because `tools/migrate-volume.sh` does not exist.

- [ ] **Step 3: Write the tool**

Create `tools/migrate-volume.sh` with exactly:

```bash
#!/usr/bin/env bash
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"

usage() {
  printf 'usage: %s <volume> <absolute-destination>\n' "$0" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage
volume="$1"
dest="$2"
[[ -n "$volume" && -n "$dest" ]] || usage
[[ "$dest" == /* ]] || {
  printf 'destination must be absolute: %s\n' "$dest" >&2
  exit 1
}

"$DOCKER_BIN" volume inspect "$volume" >/dev/null
if ! in_use="$("$DOCKER_BIN" ps -q --filter "volume=$volume")"; then
  printf 'cannot check whether volume is in use: %s\n' "$volume" >&2
  exit 1
fi
if [[ -n "$in_use" ]]; then
  printf 'volume is in use by a running container: %s\n' "$volume" >&2
  exit 1
fi

mkdir -p "$dest"
if ! entries="$(ls -A -- "$dest")"; then
  printf 'cannot inspect destination: %s\n' "$dest" >&2
  exit 1
fi
if [[ -n "$entries" ]]; then
  printf 'destination is not empty: %s\n' "$dest" >&2
  exit 1
fi

"$DOCKER_BIN" run --rm \
  -v "$volume:/from:ro" \
  -v "$dest:/to" \
  alpine:3.20 sh -c 'cp -a /from/. /to/'
```

- [ ] **Step 4: Run the test**

```bash
chmod +x tools/migrate-volume.sh
./tests/migrate_volume_test.sh
```

Expected: `migrate volume tests passed`.

- [ ] **Step 5: Commit**

```bash
git add tools/migrate-volume.sh tests/migrate_volume_test.sh tests/lib.sh
git commit -m "feat: add volume migration tool"
```

---

### Task 2: Create the new service data directories in `stack init`

**Files:**
- Modify: `stack`
- Modify: `tests/lib.sh`
- Create: `tests/init_services_test.sh`

- [ ] **Step 1: Add `assert_dir` to the shared test helper**

In `tests/lib.sh`, after `assert_file`, add exactly:

```bash
assert_dir() {
  [[ -d "$1" ]] || fail "missing directory: $1"
}
```

- [ ] **Step 2: Write the failing init-services test**

Create `tests/init_services_test.sh` with exactly:

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

repo="$TMP/repo"
make_repo "$repo"

for svc in immich tandoor authentik papra checkmate; do
  mkdir -p "$repo/$svc"
  printf 'SERVICE_VALUE=test\n' > "$repo/$svc/.env.example"
  printf 'SERVICE_SECRET=\n' > "$repo/$svc/.secrets.example"
done

cp "$repo/.env.example" "$repo/.env"
sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$TMP/data|" "$repo/.env"
sed -i "s|^ENABLED_SERVICES=.*|ENABLED_SERVICES=jellyfin,immich,tandoor,authentik,papra,checkmate|" "$repo/.env"

"$repo/stack" init >/dev/null

for dir in \
  jellyfin/config jellyfin/cache \
  immich/postgres immich/model-cache immich/redis \
  tandoor/postgresql tandoor/staticfiles tandoor/mediafiles \
  authentik/database authentik/media authentik/certs authentik/custom-templates \
  papra/app-data \
  checkmate/mongo-data checkmate/mongo-configdb; do
  assert_dir "$TMP/data/$dir"
done

printf 'init service tests passed\n'
```

- [ ] **Step 3: Run it to verify failure**

```bash
chmod +x tests/init_services_test.sh
./tests/init_services_test.sh
```

Expected: FAIL with `missing directory: .../data/immich/postgres`.

- [ ] **Step 4: Extend the `cmd_init` case**

In `stack`, replace the existing `case "$svc" in` block inside `cmd_init` with:

```bash
    case "$svc" in
      jellyfin)
        mkdir -p "$DATA_ROOT/jellyfin/config" "$DATA_ROOT/jellyfin/cache"
        ;;
      immich)
        mkdir -p "$DATA_ROOT/immich/postgres" "$DATA_ROOT/immich/model-cache" "$DATA_ROOT/immich/redis"
        ;;
      tandoor)
        mkdir -p "$DATA_ROOT/tandoor/postgresql" "$DATA_ROOT/tandoor/staticfiles" "$DATA_ROOT/tandoor/mediafiles"
        ;;
      authentik)
        mkdir -p "$DATA_ROOT/authentik/database" "$DATA_ROOT/authentik/media" "$DATA_ROOT/authentik/certs" "$DATA_ROOT/authentik/custom-templates"
        ;;
      papra)
        mkdir -p "$DATA_ROOT/papra/app-data"
        ;;
      checkmate)
        mkdir -p "$DATA_ROOT/checkmate/mongo-data" "$DATA_ROOT/checkmate/mongo-configdb"
        ;;
      *)
        mkdir -p "$DATA_ROOT/$svc"
        ;;
    esac
```

- [ ] **Step 5: Run the test**

```bash
./tests/init_services_test.sh
```

Expected: `init service tests passed`.

- [ ] **Step 6: Commit**

```bash
git add stack tests/lib.sh tests/init_services_test.sh
git commit -m "feat: create data directories for phase 2 services"
```

---

### Task 3: Add shared render helpers and convert Immich

**Files:**
- Create: `tests/render_lib.sh`
- Create: `tests/fixtures/jellyfin.env`
- Create: `tests/fixtures/jellyfin.secrets`
- Create: `tests/fixtures/immich.env`
- Create: `tests/fixtures/immich.secrets`
- Create: `tests/render_immich_test.sh`
- Create: `immich/compose.yaml`
- Create: `immich/.env.example`
- Create: `immich/.secrets.example`

- [ ] **Step 1: Write the shared render helper**

Create `tests/render_lib.sh` with exactly:

```bash
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
```

- [ ] **Step 2: Write the fixtures used by this task**

Create `tests/fixtures/jellyfin.env` with exactly:

```dotenv
JELLYFIN_MEDIA_PATH=/tmp/media
```

Create `tests/fixtures/jellyfin.secrets` with exactly:

```dotenv
# Jellyfin has no secrets.
```

Create `tests/fixtures/immich.env` with exactly:

```dotenv
IMMICH_UPLOAD_LOCATION=/tmp/immich-media
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
```

Create `tests/fixtures/immich.secrets` with exactly:

```dotenv
DB_PASSWORD=test-password
```

- [ ] **Step 3: Write the failing Immich render test**

Create `tests/render_immich_test.sh` with exactly:

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/render_lib.sh"

write_root_env
copy_service immich
install_fixture immich

rendered="$(render_service immich .env .secrets)"
rendered_json="$(render_service_json immich .env .secrets)"

assert_render_contains "$rendered" 'name: immich' 'project name missing'
assert_render_contains "$rendered" "Host(\`photos.example.test\`)" 'host rule missing'
assert_render_contains "$rendered" 'http://127.0.0.1:2283' 'upstream missing'
assert_render_contains "$rendered" 'host_ip: 127.0.0.1' 'port is not loopback-bound'
assert_render_contains "$rendered" "$TMP/data/immich/postgres" 'postgres bind missing'
assert_render_contains "$rendered" "$TMP/data/immich/model-cache" 'model cache bind missing'
assert_render_contains "$rendered" "$TMP/data/immich/redis" 'redis bind missing'
assert_no_volumes "$rendered_json"
assert_mount "$rendered_json" /tmp/immich-media /data 'uploads bind missing or wrong target'
assert_mount "$rendered_json" "$TMP/data/immich/postgres" /var/lib/postgresql/data 'postgres bind missing or wrong target'
assert_mount "$rendered_json" "$TMP/data/immich/model-cache" /cache 'model cache bind missing or wrong target'
assert_mount "$rendered_json" "$TMP/data/immich/redis" /data 'redis bind missing or wrong target'
assert_service_env "$rendered_json" immich-server DB_PASSWORD test-password 'immich-server is not loading DB_PASSWORD from .secrets'
assert_service_env "$rendered_json" database POSTGRES_PASSWORD test-password 'database password missing'

printf 'immich render tests passed\n'
```

- [ ] **Step 4: Run it to verify failure**

```bash
chmod +x tests/render_immich_test.sh
./tests/render_immich_test.sh
```

Expected: FAIL because `immich/compose.yaml` does not exist.

- [ ] **Step 5: Write the Immich env templates**

Create `immich/.env.example` with exactly:

```dotenv
# Upload location on the host. May be outside DATA_ROOT for large libraries.
# Existing servers: set this to the old UPLOAD_LOCATION value
# (for example /mnt/seagate/Media/Photos).
IMMICH_UPLOAD_LOCATION=/srv/media/immich

# Database values. The password belongs in .secrets.
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
```

Create `immich/.secrets.example` with exactly:

```dotenv
# Existing servers: copy the old DB_PASSWORD here, not into .env.
DB_PASSWORD=
```

- [ ] **Step 6: Write the Immich compose file**

Create `immich/compose.yaml` with exactly:

```yaml
name: immich

services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:v2@sha256:4504d794123c3f5410cc45bbc61e4d7dbcacec1e1b0cd2e599691430c94e5849
    restart: unless-stopped
    env_file:
      - .env
      - .secrets
    ports:
      - "127.0.0.1:2283:2283"
    volumes:
      - ${IMMICH_UPLOAD_LOCATION}:/data
      - /etc/localtime:/etc/localtime:ro
    depends_on:
      - redis
      - database
    labels:
      - traefik.enable=true
      - traefik.http.routers.immich.rule=Host(`photos.${BASE_DOMAIN}`)
      - traefik.http.routers.immich.entrypoints=websecure
      - traefik.http.routers.immich.tls.certresolver=le
      - traefik.http.services.immich.loadbalancer.server.url=http://127.0.0.1:2283

  immich-machine-learning:
    container_name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:v2@sha256:bf339cbb44af6c2ef25d9128e1da51b2bec0cfd524846a83e3017c21bd71ddb4
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - ${DATA_ROOT}/immich/model-cache:/cache

  redis:
    container_name: immich_redis
    image: docker.io/valkey/valkey:8@sha256:81db6d39e1bba3b3ff32bd3a1b19a6d69690f94a3954ec131277b9a26b95b3aa
    restart: unless-stopped
    volumes:
      - ${DATA_ROOT}/immich/redis:/data
    healthcheck:
      test: redis-cli ping || exit 1

  database:
    container_name: immich_postgres
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: "--data-checksums"
    volumes:
      - ${DATA_ROOT}/immich/postgres:/var/lib/postgresql/data
    shm_size: 128mb
```

- [ ] **Step 7: Run the render test**

```bash
./tests/render_immich_test.sh
```

Expected: `immich render tests passed`.

- [ ] **Step 8: Commit**

```bash
git add immich tests/render_lib.sh tests/fixtures tests/render_immich_test.sh
git commit -m "feat: add Immich stack"
```

---

### Task 4: Convert Tandoor

**Files:**
- Create: `tandoor/compose.yaml`
- Create: `tandoor/.env.example`
- Create: `tandoor/.secrets.example`
- Create: `tests/fixtures/tandoor.env`
- Create: `tests/fixtures/tandoor.secrets`
- Create: `tests/render_tandoor_test.sh`

- [ ] **Step 1: Write the fixtures**

Create `tests/fixtures/tandoor.env` with exactly:

```dotenv
DB_ENGINE=django.db.backends.postgresql
POSTGRES_HOST=db_recipes
POSTGRES_DB=djangodb
POSTGRES_PORT=5432
POSTGRES_USER=djangouser
EMAIL_HOST=smtp.example.test
EMAIL_PORT=587
EMAIL_HOST_USER=recipes@example.test
EMAIL_USE_TLS=1
EMAIL_USE_SSL=0
DEFAULT_FROM_EMAIL=recipes@example.test
```

Create `tests/fixtures/tandoor.secrets` with exactly:

```dotenv
SECRET_KEY=test-secret
POSTGRES_PASSWORD=test-password
EMAIL_HOST_PASSWORD=test-password
```

- [ ] **Step 2: Write the failing Tandoor render test**

Create `tests/render_tandoor_test.sh` with exactly:

```bash
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

printf 'tandoor render tests passed\n'
```

- [ ] **Step 3: Run it to verify failure**

```bash
chmod +x tests/render_tandoor_test.sh
./tests/render_tandoor_test.sh
```

Expected: FAIL because `tandoor/compose.yaml` does not exist.

- [ ] **Step 4: Write the Tandoor env templates**

Create `tandoor/.env.example` with exactly:

```dotenv
# Non-secret application values. Keep secrets in .secrets.
DB_ENGINE=django.db.backends.postgresql
POSTGRES_HOST=db_recipes
POSTGRES_DB=djangodb
POSTGRES_PORT=5432
POSTGRES_USER=djangouser
EMAIL_HOST=smtp.example.com
EMAIL_PORT=587
EMAIL_HOST_USER=recipes@example.com
EMAIL_USE_TLS=1
EMAIL_USE_SSL=0
DEFAULT_FROM_EMAIL=recipes@example.com
```

Create `tandoor/.secrets.example` with exactly:

```dotenv
SECRET_KEY=
POSTGRES_PASSWORD=
EMAIL_HOST_PASSWORD=
```

- [ ] **Step 5: Write the Tandoor compose file**

Create `tandoor/compose.yaml` with exactly:

```yaml
name: tandoor

services:
  db_recipes:
    container_name: tandoor-db_recipes-1
    image: postgres:16-alpine@sha256:23e88eb049fd5d54894d70100df61d38a49ed97909263f79d4ff4c30a5d5fca2
    restart: unless-stopped
    env_file:
      - .env
      - .secrets
    volumes:
      - ${DATA_ROOT}/tandoor/postgresql:/var/lib/postgresql/data

  web_recipes:
    container_name: tandoor-web_recipes-1
    image: vabene1111/recipes:latest@sha256:f6c58afdea7a721d079ebd6ee5483f2c9da77dd1e709e16d60a82c218e80a451
    restart: unless-stopped
    env_file:
      - .env
      - .secrets
    environment:
      TZ: ${TZ}
      ALLOWED_HOSTS: recipes.${BASE_DOMAIN}
    ports:
      - "127.0.0.1:8979:80"
    volumes:
      - ${DATA_ROOT}/tandoor/staticfiles:/opt/recipes/staticfiles
      - ${DATA_ROOT}/tandoor/mediafiles:/opt/recipes/mediafiles
    depends_on:
      - db_recipes
    labels:
      - traefik.enable=true
      - traefik.http.routers.tandoor.rule=Host(`recipes.${BASE_DOMAIN}`)
      - traefik.http.routers.tandoor.entrypoints=websecure
      - traefik.http.routers.tandoor.tls.certresolver=le
      - traefik.http.services.tandoor.loadbalancer.server.url=http://127.0.0.1:8979
```

- [ ] **Step 6: Run the render test**

```bash
./tests/render_tandoor_test.sh
```

Expected: `tandoor render tests passed`.

- [ ] **Step 7: Commit**

```bash
git add tandoor tests/fixtures/tandoor.env tests/fixtures/tandoor.secrets tests/render_tandoor_test.sh
git commit -m "feat: add Tandoor stack"
```

---

### Task 5: Convert Authentik

**Files:**
- Create: `authentik/compose.yaml`
- Create: `authentik/.env.example`
- Create: `authentik/.secrets.example`
- Create: `tests/fixtures/authentik.env`
- Create: `tests/fixtures/authentik.secrets`
- Create: `tests/render_authentik_test.sh`

- [ ] **Step 1: Write the fixtures**

Create `tests/fixtures/authentik.env` with exactly:

```dotenv
PG_DB=authentik
PG_USER=authentik
```

Create `tests/fixtures/authentik.secrets` with exactly:

```dotenv
PG_PASS=test-password
AUTHENTIK_SECRET_KEY=test-secret
```

- [ ] **Step 2: Write the failing Authentik render test**

Create `tests/render_authentik_test.sh` with exactly:

```bash
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
```

- [ ] **Step 3: Run it to verify failure**

```bash
chmod +x tests/render_authentik_test.sh
./tests/render_authentik_test.sh
```

Expected: FAIL because `authentik/compose.yaml` does not exist.

- [ ] **Step 4: Write the Authentik env templates**

Create `authentik/.env.example` with exactly:

```dotenv
PG_DB=authentik
PG_USER=authentik
```

Create `authentik/.secrets.example` with exactly:

```dotenv
PG_PASS=
AUTHENTIK_SECRET_KEY=
```

- [ ] **Step 5: Write the Authentik compose file**

Create `authentik/compose.yaml` with exactly:

```yaml
name: authentik

services:
  postgresql:
    container_name: authentik-postgresql-1
    image: postgres:16-alpine@sha256:23e88eb049fd5d54894d70100df61d38a49ed97909263f79d4ff4c30a5d5fca2
    restart: unless-stopped
    env_file:
      - .env
      - .secrets
    environment:
      POSTGRES_DB: ${PG_DB}
      POSTGRES_USER: ${PG_USER}
      POSTGRES_PASSWORD: ${PG_PASS}
    volumes:
      - ${DATA_ROOT}/authentik/database:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d $${POSTGRES_DB} -U $${POSTGRES_USER}"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s

  server:
    container_name: authentik-server-1
    image: ghcr.io/goauthentik/server:2025.10.3@sha256:d2b66e851246e7299219b72a4ed43630a2c2bac3745eb665834b72963d836e64
    command: server
    restart: unless-stopped
    env_file:
      - .env
      - .secrets
    environment:
      AUTHENTIK_POSTGRESQL__HOST: postgresql
      AUTHENTIK_POSTGRESQL__NAME: ${PG_DB}
      AUTHENTIK_POSTGRESQL__USER: ${PG_USER}
      AUTHENTIK_POSTGRESQL__PASSWORD: ${PG_PASS}
      AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET_KEY}
    ports:
      - "127.0.0.1:9000:9000"
    volumes:
      - ${DATA_ROOT}/authentik/media:/media
      - ${DATA_ROOT}/authentik/custom-templates:/templates
    depends_on:
      postgresql:
        condition: service_healthy
    labels:
      - traefik.enable=true
      - traefik.http.routers.authentik.rule=Host(`id.${BASE_DOMAIN}`)
      - traefik.http.routers.authentik.entrypoints=websecure
      - traefik.http.routers.authentik.tls.certresolver=le
      - traefik.http.services.authentik.loadbalancer.server.url=http://127.0.0.1:9000

  worker:
    container_name: authentik-worker-1
    image: ghcr.io/goauthentik/server:2025.10.3@sha256:d2b66e851246e7299219b72a4ed43630a2c2bac3745eb665834b72963d836e64
    command: worker
    restart: unless-stopped
    user: root
    env_file:
      - .env
      - .secrets
    environment:
      AUTHENTIK_POSTGRESQL__HOST: postgresql
      AUTHENTIK_POSTGRESQL__NAME: ${PG_DB}
      AUTHENTIK_POSTGRESQL__USER: ${PG_USER}
      AUTHENTIK_POSTGRESQL__PASSWORD: ${PG_PASS}
      AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET_KEY}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${DATA_ROOT}/authentik/media:/media
      - ${DATA_ROOT}/authentik/certs:/certs
      - ${DATA_ROOT}/authentik/custom-templates:/templates
    depends_on:
      postgresql:
        condition: service_healthy
```

- [ ] **Step 6: Run the render test**

```bash
./tests/render_authentik_test.sh
```

Expected: `authentik render tests passed`.

- [ ] **Step 7: Commit**

```bash
git add authentik tests/fixtures/authentik.env tests/fixtures/authentik.secrets tests/render_authentik_test.sh
git commit -m "feat: add Authentik stack"
```

---

### Task 6: Convert Papra

**Files:**
- Create: `papra/compose.yaml`
- Create: `papra/.env.example`
- Create: `papra/.secrets.example`
- Create: `tests/fixtures/papra.env`
- Create: `tests/fixtures/papra.secrets`
- Create: `tests/render_papra_test.sh`

- [ ] **Step 1: Write the fixtures**

Create `tests/fixtures/papra.env` with exactly:

```dotenv
PAPRA_OIDC_CLIENT_ID=test-client-id
```

Create `tests/fixtures/papra.secrets` with exactly:

```dotenv
AUTH_SECRET=test-secret
PAPRA_OIDC_CLIENT_SECRET=test-client-secret
```

- [ ] **Step 2: Write the failing Papra render test**

Create `tests/render_papra_test.sh` with exactly:

```bash
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
```

- [ ] **Step 3: Run it to verify failure**

```bash
chmod +x tests/render_papra_test.sh
./tests/render_papra_test.sh
```

Expected: FAIL because `papra/compose.yaml` does not exist.

- [ ] **Step 4: Write the Papra env templates**

Create `papra/.env.example` with exactly:

```dotenv
# Authentik OIDC client values. The client secret belongs in .secrets.
# Existing servers: copy the client ID from the old Authentik/OIDC config.
PAPRA_OIDC_CLIENT_ID=
```

Create `papra/.secrets.example` with exactly:

```dotenv
# Existing servers: copy AUTH_SECRET and set the OIDC client secret here.
# Use the URL-safe secret generated by Authentik (no quotes or backslashes);
# rotate it if it has been exposed.
AUTH_SECRET=
PAPRA_OIDC_CLIENT_SECRET=
```

- [ ] **Step 5: Write the Papra compose file**

Create `papra/compose.yaml` with exactly:

```yaml
name: papra

services:
  papra:
    container_name: papra
    image: ghcr.io/papra-hq/papra:latest@sha256:9b3ddb66c63caf9d2616a2cb47689d39af4efd4ed19bffdf1943a8a262719c35
    restart: unless-stopped
    user: "${PUID:-1000}:${PGID:-1000}"
    env_file:
      - .env
      - .secrets
    environment:
      TZ: ${TZ}
      APP_BASE_URL: https://docs.${BASE_DOMAIN}
      AUTH_PROVIDERS_EMAIL_IS_ENABLED: "false"
      AUTH_PROVIDERS_CUSTOMS: >-
        [{"providerId":"authentik","providerName":"authentik","providerIconUrl":"https://id.${BASE_DOMAIN}/static/dist/assets/icons/icon.png","clientId":"${PAPRA_OIDC_CLIENT_ID}","clientSecret":"${PAPRA_OIDC_CLIENT_SECRET}","type":"oidc","discoveryUrl":"https://id.${BASE_DOMAIN}/application/o/papra/.well-known/openid-configuration","scopes":["openid","profile","email"]}]
    ports:
      - "127.0.0.1:1221:1221"
    volumes:
      - ${DATA_ROOT}/papra/app-data:/app/app-data
    labels:
      - traefik.enable=true
      - traefik.http.routers.papra.rule=Host(`docs.${BASE_DOMAIN}`)
      - traefik.http.routers.papra.entrypoints=websecure
      - traefik.http.routers.papra.tls.certresolver=le
      - traefik.http.services.papra.loadbalancer.server.url=http://127.0.0.1:1221
```

- [ ] **Step 6: Run the render test**

```bash
./tests/render_papra_test.sh
```

Expected: `papra render tests passed`.

- [ ] **Step 7: Commit**

```bash
git add papra tests/fixtures/papra.env tests/fixtures/papra.secrets tests/render_papra_test.sh
git commit -m "feat: add Papra stack"
```

---

### Task 7: Convert Checkmate

**Files:**
- Create: `checkmate/compose.yaml`
- Create: `checkmate/compose.override.yaml.example`
- Create: `checkmate/.env.example`
- Create: `checkmate/.secrets.example`
- Create: `tests/fixtures/checkmate.env`
- Create: `tests/fixtures/checkmate.secrets`
- Create: `tests/render_checkmate_test.sh`

- [ ] **Step 1: Write the fixtures**

Create `tests/fixtures/checkmate.env` with exactly:

```dotenv
# Checkmate has no non-secret values.
```

Create `tests/fixtures/checkmate.secrets` with exactly:

```dotenv
JWT_SECRET=test-jwt
ENCRYPTION_KEY=test-encryption
CAPTURE_API_SECRET=test-capture
```

- [ ] **Step 2: Write the failing Checkmate render test**

Create `tests/render_checkmate_test.sh` with exactly:

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/render_lib.sh"

write_root_env
copy_service checkmate
install_fixture checkmate

rendered="$(render_service checkmate .env .secrets)"
rendered_json="$(render_service_json checkmate .env .secrets)"

assert_render_contains "$rendered" 'name: checkmate' 'project name missing'
assert_render_contains "$rendered" 'container_name: checkmate-checkmate-1' 'checkmate container name missing'
assert_render_contains "$rendered" 'container_name: checkmate-mongodb-1' 'mongodb container name missing'
assert_render_contains "$rendered" 'container_name: checkmate-capture-1' 'capture container name missing'
assert_render_contains "$rendered" "Host(\`status.example.test\`)" 'status host rule missing'
assert_render_contains "$rendered" "Host(\`info.status.example.test\`)" 'info status host rule missing'
assert_render_contains "$rendered" 'http://127.0.0.1:52345' 'upstream missing'
assert_render_contains "$rendered" 'host_ip: 127.0.0.1' 'port is not loopback-bound'
assert_render_contains "$rendered" "$TMP/data/checkmate/mongo-data" 'mongo data bind missing'
assert_render_contains "$rendered" "$TMP/data/checkmate/mongo-configdb" 'mongo configdb bind missing'
assert_render_contains "$rendered" 'source: /var/run/docker.sock' 'docker socket bind missing'
assert_no_volumes "$rendered_json"
assert_mount "$rendered_json" "$TMP/data/checkmate/mongo-data" /data/db 'mongo data bind missing or wrong target' mongodb
assert_mount "$rendered_json" "$TMP/data/checkmate/mongo-configdb" /data/configdb 'mongo configdb bind missing or wrong target' mongodb
assert_mount "$rendered_json" /var/run/docker.sock /var/run/docker.sock 'checkmate docker socket bind missing' checkmate
assert_mount_read_only "$rendered_json" checkmate /var/run/docker.sock /var/run/docker.sock 'docker socket is not read-only'
assert_no_service_mount "$rendered_json" mongodb /var/run/docker.sock /var/run/docker.sock 'mongodb must not mount the docker socket'
assert_no_service_mount "$rendered_json" capture /var/run/docker.sock /var/run/docker.sock 'capture must not mount the docker socket'
assert_mount_read_only "$rendered_json" capture /etc/os-release /etc/os-release 'capture os-release bind is not read-only'
assert_mount_read_only "$rendered_json" capture /mnt/old-home /mnt/old-home 'capture old-home bind is not read-only'
assert_mount_read_only "$rendered_json" capture /mnt/seagate /mnt/seagate 'capture seagate bind is not read-only'
assert_render_contains "$rendered" 'stop_grace_period: 1m0s' 'stop grace period missing'
assert_render_contains "$rendered" 'sha256:bccfe26411a52590ec67e9c6a890a66c154e10b89a7598c6ae00262f3a88b3de' 'checkmate image digest missing'
assert_render_contains "$rendered" 'sha256:4a4ab5d4834207389e0d7270fac988e21ffedccecba77991a552f755df229907' 'mongo image digest missing'
assert_render_contains "$rendered" 'sha256:c4917c572b12d4068b5987494132da728363591ec9227a116ef07cd77222292f' 'capture image digest missing'
assert_render_contains "$rendered" 'http://localhost:52346/livez' 'checkmate healthcheck missing'
assert_render_contains "$rendered" "db.adminCommand('ping')" 'mongodb healthcheck missing'
assert_service_env "$rendered_json" checkmate DB_CONNECTION_STRING mongodb://mongodb:27017/uptime_db 'database connection string missing'
assert_service_env "$rendered_json" checkmate CLIENT_HOST https://status.example.test 'client host missing'
assert_service_env "$rendered_json" checkmate CLIENT_CONFIG_CLIENT_HOST https://status.example.test 'client config host missing'
assert_service_env "$rendered_json" checkmate JWT_SECRET test-jwt 'checkmate JWT secret missing'
assert_service_env "$rendered_json" checkmate ENCRYPTION_KEY test-encryption 'checkmate encryption key missing'
assert_service_env_absent "$rendered_json" checkmate CAPTURE_API_SECRET 'checkmate must not receive the capture secret'
assert_service_env "$rendered_json" capture API_SECRET test-capture 'capture API secret missing'
assert_service_env "$rendered_json" capture GIN_MODE release 'capture mode missing'
assert_service_env_absent "$rendered_json" capture JWT_SECRET 'capture must not receive JWT_SECRET'
assert_service_env_absent "$rendered_json" capture ENCRYPTION_KEY 'capture must not receive ENCRYPTION_KEY'
assert_service_env_absent "$rendered_json" capture CAPTURE_API_SECRET 'capture must not receive the raw capture secret'

cp "$TMP/checkmate/.secrets" "$TMP/checkmate/.secrets-missing"
sed -i '/^CAPTURE_API_SECRET=/d' "$TMP/checkmate/.secrets-missing"
if render_service checkmate .env .secrets-missing >/dev/null 2>&1; then
  fail "rendered without CAPTURE_API_SECRET"
fi

printf 'checkmate render tests passed\n'
```

- [ ] **Step 3: Run it to verify failure**

```bash
chmod +x tests/render_checkmate_test.sh
./tests/render_checkmate_test.sh
```

Expected: FAIL because `checkmate/compose.yaml` does not exist.

- [ ] **Step 4: Write the Checkmate env templates**

Create `checkmate/.env.example` with exactly:

```dotenv
# Checkmate has no non-secret values. Host-specific group settings belong in
# compose.override.yaml.
```

Create `checkmate/.secrets.example` with exactly:

```dotenv
# Existing servers: preserve ENCRYPTION_KEY and CAPTURE_API_SECRET.
# Generate a new JWT_SECRET; do not reuse the exposed JWT secret.
JWT_SECRET=
ENCRYPTION_KEY=
CAPTURE_API_SECRET=
```

- [ ] **Step 5: Write the Checkmate compose file**

Create `checkmate/compose.yaml` with exactly:

```yaml
name: checkmate

services:
  checkmate:
    container_name: checkmate-checkmate-1
    image: ghcr.io/bluewave-labs/checkmate:latest@sha256:bccfe26411a52590ec67e9c6a890a66c154e10b89a7598c6ae00262f3a88b3de
    restart: unless-stopped
    stop_grace_period: 60s
    env_file:
      - .env
    environment:
      JWT_SECRET: ${JWT_SECRET}
      ENCRYPTION_KEY: ${ENCRYPTION_KEY}
      DB_CONNECTION_STRING: mongodb://mongodb:27017/uptime_db
      CLIENT_HOST: https://status.${BASE_DOMAIN}
      CLIENT_CONFIG_CLIENT_HOST: https://status.${BASE_DOMAIN}
    ports:
      - "127.0.0.1:52345:52345"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://localhost:52346/livez',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
      interval: 15s
      timeout: 3s
      start_period: 60s
      start_interval: 2s
      retries: 3
    depends_on:
      mongodb:
        condition: service_healthy
    labels:
      - traefik.enable=true
      - "traefik.http.routers.checkmate.rule=Host(`status.${BASE_DOMAIN}`) || Host(`info.status.${BASE_DOMAIN}`)"
      - traefik.http.routers.checkmate.entrypoints=websecure
      - traefik.http.routers.checkmate.tls.certresolver=le
      - traefik.http.services.checkmate.loadbalancer.server.url=http://127.0.0.1:52345

  mongodb:
    container_name: checkmate-mongodb-1
    image: mongo:8.0@sha256:4a4ab5d4834207389e0d7270fac988e21ffedccecba77991a552f755df229907
    restart: unless-stopped
    command: ["mongod", "--quiet", "--bind_ip_all"]
    volumes:
      - ${DATA_ROOT}/checkmate/mongo-data:/data/db
      - ${DATA_ROOT}/checkmate/mongo-configdb:/data/configdb
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')", "--quiet"]
      interval: 5s
      timeout: 30s
      start_period: 0s
      start_interval: 1s
      retries: 30

  capture:
    container_name: checkmate-capture-1
    image: ghcr.io/bluewave-labs/capture:latest@sha256:c4917c572b12d4068b5987494132da728363591ec9227a116ef07cd77222292f
    restart: unless-stopped
    environment:
      GIN_MODE: release
      API_SECRET: ${CAPTURE_API_SECRET:?CAPTURE_API_SECRET is required}
    volumes:
      - /etc/os-release:/etc/os-release:ro
      - /mnt/old-home:/mnt/old-home:ro
      - /mnt/seagate:/mnt/seagate:ro
```

- [ ] **Step 6: Write the host override example**

Create `checkmate/compose.override.yaml.example` with exactly:

```yaml
services:
  checkmate:
    group_add:
      - "957"
```

The real `checkmate/compose.override.yaml` is gitignored. It is required on the
reference server so the container can access the Docker socket group.

- [ ] **Step 7: Run the render test**

```bash
./tests/render_checkmate_test.sh
```

Expected: `checkmate render tests passed`.

- [ ] **Step 8: Commit**

```bash
git add checkmate tests/fixtures/checkmate.env tests/fixtures/checkmate.secrets tests/render_checkmate_test.sh tests/render_lib.sh
git commit -m "feat: add Checkmate stack"
```

---

### Task 8: Add consolidated data-safety coverage and CI

**Files:**
- Create: `tests/data_safety_phase2_test.sh`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the consolidated data-safety test**

Create `tests/data_safety_phase2_test.sh` with exactly:

```bash
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
```

- [ ] **Step 2: Run it**

```bash
chmod +x tests/data_safety_phase2_test.sh
./tests/data_safety_phase2_test.sh
```

Expected: `phase 2 data safety tests passed`.

- [ ] **Step 3: Replace the CI workflow**

Replace `.github/workflows/ci.yml` with exactly:

```yaml
name: ci

on:
  push:
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install shellcheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck

      - name: Shellcheck
        run: shellcheck stack tests/*.sh tools/*.sh

      - name: Stack tests
        run: |
          ./tests/init_test.sh
          ./tests/check_test.sh
          ./tests/lifecycle_test.sh
          ./tests/update_test.sh
          ./tests/init_services_test.sh
          ./tests/migrate_volume_test.sh

      - name: Compose render tests
        run: ./tests/compose_render_test.sh

      - name: Phase 2 render tests
        run: |
          ./tests/render_immich_test.sh
          ./tests/render_tandoor_test.sh
          ./tests/render_authentik_test.sh
          ./tests/render_papra_test.sh
          ./tests/render_checkmate_test.sh

      - name: Data safety tests
        run: |
          ./tests/data_safety_test.sh
          ./tests/data_safety_phase2_test.sh
```

- [ ] **Step 4: Run shellcheck and the full suite**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable stack tests/*.sh tools/*.sh
./tests/init_test.sh
./tests/check_test.sh
./tests/lifecycle_test.sh
./tests/update_test.sh
./tests/init_services_test.sh
./tests/migrate_volume_test.sh
./tests/compose_render_test.sh
./tests/render_immich_test.sh
./tests/render_tandoor_test.sh
./tests/render_authentik_test.sh
./tests/render_papra_test.sh
./tests/render_checkmate_test.sh
./tests/data_safety_test.sh
./tests/data_safety_phase2_test.sh
```

Expected: shellcheck exits 0 and every script prints its `passed` line.

- [ ] **Step 5: Commit**

```bash
git add tests/data_safety_phase2_test.sh .github/workflows/ci.yml
git commit -m "test: cover phase 2 service rendering and data safety"
```

---

### Task 9: Update the docs and the server move runbook

**Files:**
- Modify: `.gitignore`
- Modify: `README.md`
- Modify: `docs/operations.md`
- Modify: `docs/adopt-existing-server.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Update the README services section**

In `README.md`, replace the existing `## Services` section with:

```markdown
## Services

| Service | Domain | Upstream | Status |
| --- | --- | --- | --- |
| Jellyfin | `flix.<base>` | `127.0.0.1:8096` | converted |
| Immich | `photos.<base>` | `127.0.0.1:2283` | converted |
| Tandoor | `recipes.<base>` | `127.0.0.1:8979` | converted |
| Authentik | `id.<base>` | `127.0.0.1:9000` | converted |
| Papra | `docs.<base>` | `127.0.0.1:1221` | converted |
| Checkmate | `status.<base>` / `info.status.<base>` | `127.0.0.1:52345` | converted |

All public services are converted to per-service directories. nginx still owns
ports 80 and 443 until Phase 3 cuts ingress over to Traefik.
```

- [ ] **Step 2: Add the volume-move procedure to `docs/operations.md`**

Immediately after the `## Data safety` section, insert:

````markdown
## Migrating existing named volumes

Run only the block for the service being swapped; do not run all four at once.
Do not stop all four volume owners together; stopping Authentik early breaks
Papra OIDC logins.

Stop the owning container before copying. The tool refuses a non-empty
destination. If a copy fails partway, remove only that failed partial copy;
never delete a populated destination.

```bash
set -euo pipefail
set -a
. ./.env
set +a
: "${DATA_ROOT:?run from the repo root with .env loaded}"
```

```bash
# Immich
docker stop --time 60 immich_machine_learning
./tools/migrate-volume.sh immich_model-cache "$DATA_ROOT/immich/model-cache"
```

```bash
# Tandoor
docker stop --time 60 tandoor-web_recipes-1
./tools/migrate-volume.sh tandoor_staticfiles "$DATA_ROOT/tandoor/staticfiles"
```

```bash
# Checkmate
docker stop --time 60 checkmate-mongodb-1
./tools/migrate-volume.sh checkmate_mongo-data "$DATA_ROOT/checkmate/mongo-data"
```

```bash
# Authentik
docker stop --time 60 authentik-postgresql-1
./tools/migrate-volume.sh authentik_database "$DATA_ROOT/authentik/database"
```

Immich's Redis data is a pure cache. Start it with an empty
`${DATA_ROOT}/immich/redis` instead of copying the anonymous volume.
Checkmate's `/data/configdb` volume is empty; create
`${DATA_ROOT}/checkmate/mongo-configdb` and leave it empty.

Do not delete the old volumes until the new containers have been running and
verified for an agreed period.
````

- [ ] **Step 3: Harden the adoption runbook preamble, backup, prepare, cutover, and rollback**

In `docs/adopt-existing-server.md`, replace the intro paragraph with:

````markdown
This runbook is for the reference server, which currently runs nginx and
per-service compose files under `~/<service>/`. All services are already
converted to Traefik routes. Sections 1-5 and 9 are Phase 2; sections 6-8 are
Phase 3. Complete section 9 for every service before section 6.
````

Replace the whole `## 1. Back up` section with:

````markdown
## 1. Back up

```bash
set -euo pipefail
umask 077
backup="$HOME/backups/stack-$(date +%F-%H%M%S)"
mkdir -p "$HOME/backups"
mkdir "$backup"
chmod 700 "$backup"

for service in jellyfin immich tandoor authentik papra checkmate; do
  file="$HOME/$service/docker-compose.yml"
  [[ -f "$file" ]] || file="$HOME/$service/docker-compose.yaml"
  docker compose -f "$file" config > "$backup/$service.compose.resolved.yml"
  cp "$file" "$backup/$service.compose.yml"
  cp "$HOME/$service/.env" "$backup/$service.env"
done

sudo tar -C /home/layz -czf "$backup/data-root.tgz" \
  jellyfin immich tandoor authentik papra checkmate traefik

docker exec authentik-postgresql-1 pg_dump -U authentik authentik > "$backup/authentik.sql"
docker exec tandoor-db_recipes-1 pg_dump -U djangouser djangodb > "$backup/tandoor.sql"
docker exec immich_postgres pg_dump -U postgres immich > "$backup/immich.sql"
docker exec checkmate-mongodb-1 mongodump --archive --gzip > "$backup/checkmate-mongo.archive.gz"

nginx_file="$HOME/nginx/examples/docker-compose.yml"
[[ -f "$nginx_file" ]] || nginx_file="$HOME/nginx/examples/docker-compose.yaml"
cp "$nginx_file" "$backup/nginx-compose.yml"
cp -a "$HOME/nginx/examples/user_conf.d" "$backup/nginx-user_conf.d"
sudo tar -C "$HOME/nginx/examples" -czf "$backup/letsencrypt.tgz" letsencrypt

if [[ -f "$HOME/stack/.env" ]]; then
  cp "$HOME/stack/.env" "$backup/stack.env"
fi

docker volume ls > "$backup/docker-volumes.txt"
sudo chmod -R go-rwx "$backup"
```

The backup directory name includes seconds, and `mkdir` fails if the directory
already exists. Any failure stops the block. `chmod -R go-rwx` protects database
passwords, env files, resolved configs, and ACME keys.

If the backup fails, stop and fix it before continuing.

The SQL dumps and Mongo archive are the consistent database backups.
`data-root.tgz` is a best-effort filesystem copy of bind data taken while
services run. For a fully consistent database backup, stop the old services
first or rely on the dumps above. The retained old named volumes and bind
mounts are the migration rollback path; do not treat the live tar as a
database-consistent backup.

Never commit the backup directory.
````

Replace the whole `## 2. Prepare the instance` section with:

````markdown
## 2. Prepare the instance

```bash
set -euo pipefail
REPO_URL=<repo-url>
if [[ -e "$HOME/stack" ]]; then
  printf '%s already exists; move it aside or update it manually\n' "$HOME/stack" >&2
  exit 1
fi
git clone "$REPO_URL" "$HOME/stack"
cd "$HOME/stack"
cp -n .env.example .env
```

Set at least:

```dotenv
BASE_DOMAIN=priyav.dev
ACME_EMAIL=<your email>
DATA_ROOT=/home/layz
PUID=1000
PGID=1000
ENABLED_SERVICES=jellyfin,immich,tandoor,authentik,papra,checkmate
```

All six services are migrated and have Traefik routes. Keep nginx running until
Phase 3; do not cut over ingress yet.

Create `<service>/.env` and `<service>/.secrets` from the templates. Copy
existing non-secret values into `.env` and existing secrets into `.secrets`.
Set `IMMICH_UPLOAD_LOCATION` to the old `UPLOAD_LOCATION`. `chmod 600` each
`.secrets`. Do not let `./stack init` generate replacements for existing
secrets. Do not commit either file.

After populating them, back up the new repo `.env` and each service `.env` and
`.secrets` into the section 1 backup directory, using `$backup` from that shell.

Run `./stack init` and `./stack check` after the files are populated.
````

Replace the whole `## 6. Cut over ingress` section with:

````markdown
**Phase 3 only. Do not run sections 6-8 until section 9 is complete for every
service.**

## 6. Cut over ingress (Phase 3)

Do this only after section 9 is complete for every service. Run `./stack check`
before stopping nginx:

```bash
./stack check
nginx_file="$HOME/nginx/examples/docker-compose.yml"
[[ -f "$nginx_file" ]] || nginx_file="$HOME/nginx/examples/docker-compose.yaml"
docker compose -f "$nginx_file" down
./stack up
```

Do not stop an old project after its new project is running. Both use the same
project name, so `docker compose down` would remove the new containers.
````

Replace the whole `## 8. Rollback` section with:

````markdown
## 8. Rollback (Phase 3)

Rollback starts the old stacks on the old volumes. Named-volume services
(Authentik database, Checkmate Mongo, Tandoor static files, Immich model cache)
lose post-swap writes on rollback because the old volumes do not contain them.
Bind-mounted services share the same paths, so their post-swap writes remain.
If writes to a named volume are needed, copy the bind path back into the old
volume before starting the old stack; otherwise accept the loss.

If Papra was swapped and the OIDC client secret was rotated:

- Full rollback including Authentik: the old Authentik still has the old OIDC
  secret, so keep the old Papra secret.
- Papra-only rollback while new Authentik remains: update the old Papra compose
  or env with the new OIDC secret.
- If you copy the new Authentik bind data back into the old volume, update old
  Papra to the new secret.

```bash
set -euo pipefail
./stack down

for service in jellyfin immich tandoor authentik papra checkmate; do
  file="$HOME/$service/docker-compose.yml"
  [[ -f "$file" ]] || file="$HOME/$service/docker-compose.yaml"
  docker compose -f "$file" up -d
done

nginx_file="$HOME/nginx/examples/docker-compose.yml"
[[ -f "$nginx_file" ]] || nginx_file="$HOME/nginx/examples/docker-compose.yaml"
docker compose -f "$nginx_file" up -d
```

Keep the old compose files and nginx certificates until the new stack has been
stable for an agreed period.
````

- [ ] **Step 4: Replace the adoption volume section**

In `docs/adopt-existing-server.md`, replace the whole `## 4. Migrate old named
volumes` section with:

````markdown
## 4. Migrate old named volumes

Run only the block for the service being swapped; do not run all four at once.
Do not stop all four volume owners together; stopping Authentik early breaks
Papra OIDC logins.

Stop the owning container, then copy its volume into the bind path. Never pass
`-v` to `docker compose down`. The tool refuses a non-empty destination. If a
copy fails partway, remove only that failed partial copy; never delete a
populated destination.

```bash
set -euo pipefail
set -a
. ./.env
set +a
: "${DATA_ROOT:?run from the repo root with .env loaded}"
```

```bash
# Immich
docker stop --time 60 immich_machine_learning
./tools/migrate-volume.sh immich_model-cache "$DATA_ROOT/immich/model-cache"
```

```bash
# Tandoor
docker stop --time 60 tandoor-web_recipes-1
./tools/migrate-volume.sh tandoor_staticfiles "$DATA_ROOT/tandoor/staticfiles"
```

```bash
# Checkmate
docker stop --time 60 checkmate-mongodb-1
./tools/migrate-volume.sh checkmate_mongo-data "$DATA_ROOT/checkmate/mongo-data"
```

```bash
# Authentik
docker stop --time 60 authentik-postgresql-1
./tools/migrate-volume.sh authentik_database "$DATA_ROOT/authentik/database"
```

Create empty directories for the disposable data:

```bash
mkdir -p /home/layz/immich/redis /home/layz/checkmate/mongo-configdb
```

Immich uploads (`/mnt/seagate/Media/Photos`), Immich Postgres
(`/home/layz/immich/postgres`), Jellyfin media (`/mnt/seagate`), Tandoor
Postgres/media, Authentik media/certs/templates, and Papra app-data are already
bind mounts and need no copy. Set `IMMICH_UPLOAD_LOCATION` to the old
`UPLOAD_LOCATION` value (`/mnt/seagate/Media/Photos` on the reference server),
and move the old `DB_PASSWORD` into `immich/.secrets`, not `immich/.env`.

Put existing secrets in each service's `.secrets`, not `.env`; `--env-file`
order makes `.secrets` win, and `stack check` validates it.

For Papra, set `PAPRA_OIDC_CLIENT_ID` to the existing client ID and preserve
`AUTH_SECRET` in `papra/.secrets` so existing sessions stay valid. Rotate only
the OIDC client secret in Authentik, immediately before the Papra swap, and put
the new URL-safe secret in `papra/.secrets`.

For Checkmate, preserve `ENCRYPTION_KEY` and `CAPTURE_API_SECRET`. Generate a
new `JWT_SECRET` with `openssl rand -hex 32` and put them in
`checkmate/.secrets`; do not reuse the exposed JWT secret. The capture service
maps `CAPTURE_API_SECRET` to `API_SECRET`.

For Tandoor, move the existing `SECRET_KEY`, `POSTGRES_PASSWORD`, and
`EMAIL_HOST_PASSWORD` into `tandoor/.secrets`. The Postgres container must use
the same `POSTGRES_PASSWORD` as the existing database.

For Authentik, move the existing `PG_PASS` and `AUTHENTIK_SECRET_KEY` into
`authentik/.secrets`. The Postgres container must use the same `PG_PASS` as the
existing database.

Do not remove the old volumes until the new stack has been verified.
````

- [ ] **Step 5: Add the soft-swap runbook**

At the end of `docs/adopt-existing-server.md`, append:

````markdown
## 9. Soft-swap one service at a time (Phase 2)

This step keeps nginx on 80/443 and swaps the container behind nginx. It is the
safe way to validate each converted stack before Phase 3. Run the commands from
the repo root (`$HOME/stack`).

For every Phase 2 service, plus the Jellyfin soft-swap:

1. Migrate only the volumes for this service using the matching pair in
   section 4, immediately before the swap.
2. Stop the old project without removing data:

   ```bash
   file="$HOME/<service>/docker-compose.yml"
   [[ -f "$file" ]] || file="$HOME/<service>/docker-compose.yaml"
   docker compose -f "$file" down
   ```

3. Start only the converted service from this repo. Add
   `-f <service>/compose.override.yaml` when that file exists. Do not run
   `./stack up` during the Phase 2 soft swaps; section 6 is the Phase 3
   cutover.
4. Verify the public URL still works through nginx.

Checkmate's old file is `docker-compose.yaml`; the others are
`docker-compose.yml`.

Example for Jellyfin:

```bash
cp -n jellyfin/compose.override.yaml.example jellyfin/compose.override.yaml
docker compose -f "$HOME/jellyfin/docker-compose.yml" down
docker compose --env-file .env --env-file jellyfin/.env --env-file jellyfin/.secrets -f jellyfin/compose.yaml -f jellyfin/compose.override.yaml up -d
curl -sI https://flix.priyav.dev/ | head
```

Example for Immich:

```bash
docker compose -f "$HOME/immich/docker-compose.yml" down
docker compose --env-file .env --env-file immich/.env --env-file immich/.secrets -f immich/compose.yaml up -d
curl -sI https://photos.priyav.dev/ | head
```

Tandoor, Authentik, and Papra follow the same pattern with `docker-compose.yml`
and no host override in this phase.

Example for Checkmate:

```bash
cp -n checkmate/compose.override.yaml.example checkmate/compose.override.yaml
docker compose -f "$HOME/checkmate/docker-compose.yaml" down
docker compose --env-file .env --env-file checkmate/.env --env-file checkmate/.secrets -f checkmate/compose.yaml -f checkmate/compose.override.yaml up -d
curl -sI https://status.priyav.dev/ | head
```

The Checkmate override is only needed if group 957 owns the Docker socket.

`docker compose -f` does not auto-merge `compose.override.yaml`; pass it
explicitly when present.

Recommended order for the five Phase 2 services, lowest risk first:

1. Immich (photos and Postgres already bind-mounted; only caches change)
2. Tandoor (Postgres and media already bind-mounted; static files copy)
3. Checkmate (Mongo data copy)
4. Authentik (Postgres data copy; verify login before moving on)
5. Papra (no data move)

Jellyfin is already converted; use it as a first soft-swap validation if
desired.

### Validate through Traefik without touching nginx

Do not run `./stack up` until Phase 3. To prove Traefik can serve a converted
service while nginx still owns 80/443, run a second Traefik on 8080/8443.

Create `traefik/compose.staging.yaml` (gitignored) with:

```yaml
name: traefik-staging
services:
  traefik:
    container_name: traefik-staging
    restart: "no"
    command:
      - --global.checkNewVersion=false
      - --global.sendAnonymousUsage=false
      - --entrypoints.web.address=:8080
      - --entrypoints.websecure.address=:8443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --providers.docker=true
      - --providers.docker.exposedByDefault=false
      - --providers.docker.endpoint=unix:///var/run/docker.sock
      - --certificatesresolvers.le.acme.email=${ACME_EMAIL}
      - --certificatesresolvers.le.acme.storage=/acme.json
      - --certificatesresolvers.le.acme.caServer=https://acme-staging-v02.api.letsencrypt.org/directory
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
      - --api.dashboard=false
      - --log.level=INFO
      - --accesslog=false
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${DATA_ROOT}/traefik/acme-staging.json:/acme.json
```

Use a separate ACME file so staging writes cannot disturb production state:

```bash
set -a
. ./.env
set +a

touch "$DATA_ROOT/traefik/acme-staging.json"
chmod 600 "$DATA_ROOT/traefik/acme-staging.json"
```

Start it and probe the Host header:

```bash
docker compose -p traefik-staging --env-file .env -f traefik/compose.yaml -f traefik/compose.staging.yaml up -d
curl -sk -H 'Host: flix.priyav.dev' https://127.0.0.1:8443/ -o /dev/null -w '%{http_code}\n'
```

Expect 200, 302, 401, or 403; a 404 can mean the router is missing or the app
has no route at `/`; verify a known application path. Certificate issuance
cannot succeed while nginx owns port 80; `-k` accepts Traefik's fallback
certificate. Repeat with each migrated Host. Then stop the staging instance and
remove the staging override and staging ACME file:

```bash
docker compose -p traefik-staging --env-file .env -f traefik/compose.yaml -f traefik/compose.staging.yaml down && {
  set -a
  . ./.env
  set +a
  rm traefik/compose.staging.yaml "$DATA_ROOT/traefik/acme-staging.json"
}
```

If an earlier attempt left `traefik/compose.override.yaml`, remove it before
Phase 3 with `rm traefik/compose.override.yaml`; `stack` auto-includes it.

Rollback for a single service. Writes made to the new bind mounts after the
swap are not copied back. If those writes are needed, copy the bind path back
into the old volume before starting the old stack; otherwise accept the loss.

For Papra: if new Authentik remains, update the old Papra compose or env with
the new OIDC secret. If you also roll back Authentik, the old Authentik still
has the old secret, so keep the old Papra secret. If you copy the new Authentik
bind data back into the old volume, update old Papra to the new secret.

Stop the new project
(`docker compose --env-file .env --env-file <service>/.env --env-file <service>/.secrets -f <service>/compose.yaml down`)
and start the old one:

```bash
set -euo pipefail
file="$HOME/<service>/docker-compose.yml"
[[ -f "$file" ]] || file="$HOME/<service>/docker-compose.yaml"
docker compose -f "$file" up -d
```

Do not run `./stack up` or `./stack down` during Phase 2; use the per-service
commands, because both operate on the whole stack and can remove still-running
old services. Do not run `./stack down -v`. Do not stop nginx until the Phase 3
cutover in section 6.
````

- [ ] **Step 6: Update `AGENTS.md`**

Replace the `## Current phase` section in `AGENTS.md` with:

```markdown
## Current phase

Phase 2 converted Immich, Tandoor, Authentik, Papra, and Checkmate. Every public
service now has a Traefik route and bind-mounted data. nginx still owns ports 80
and 443; Phase 3 performs the ingress cutover and adds the update timer. Do not
stop nginx until the cutover is explicitly scheduled.
```

- [ ] **Step 7: Commit**

Add `*/compose.staging.yaml` to `.gitignore` so the staging override stays
untracked, then:

```bash
git add .gitignore README.md docs/operations.md docs/adopt-existing-server.md AGENTS.md docs/superpowers/plans/2026-10-26-phase2-service-migration.md
git commit -m "docs: add phase 2 service migration runbook"
```

---

### Task 10: Tag the Phase 2 release

**Files:** none

- [ ] **Step 1: Run the full validation suite**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable stack tests/*.sh tools/*.sh
./tests/init_test.sh
./tests/check_test.sh
./tests/lifecycle_test.sh
./tests/update_test.sh
./tests/init_services_test.sh
./tests/migrate_volume_test.sh
./tests/compose_render_test.sh
./tests/render_immich_test.sh
./tests/render_tandoor_test.sh
./tests/render_authentik_test.sh
./tests/render_papra_test.sh
./tests/render_checkmate_test.sh
./tests/data_safety_test.sh
./tests/data_safety_phase2_test.sh
```

Expected: shellcheck exits 0 and every script prints its `passed` line.

- [ ] **Step 2: Verify no local or secret files are tracked**

```bash
git status --short
git ls-files | grep -E '(^|/)(\.env|\.secrets|\.namecheap\.env|compose\.override\.yaml)$' && exit 1 || true
```

Expected: no `.env`, `.secrets`, `.namecheap.env`, or override file in the
tracked list. The only untracked entry may be `.obsidian/`.

- [ ] **Step 3: Tag**

```bash
git tag -a v0.2.0 -m "phase 2 service migration"
git tag --list 'v*'
```

Expected: `v0.1.0` and `v0.2.0`.

Do not push until the user asks.

---

## Server rollout checklist

Run these only after the code tasks pass and the plan has been reviewed. Do not
stop nginx.

- [ ] Back up `/home/layz` (including a data-root archive), root `.env`, every
      `*/.env`, every `*/.secrets`, and `/home/layz/traefik/acme.json`.
- [ ] Create the server `.env` files from the new templates and copy existing
      values into `.env` / `.secrets` before running `./stack init`. Do not let
      `init` generate replacements for existing secrets.
- [ ] Put existing secrets in each service's `.secrets`, not `.env`: Immich
      `DB_PASSWORD`; Tandoor `SECRET_KEY`, `POSTGRES_PASSWORD`,
      `EMAIL_HOST_PASSWORD`; Authentik `PG_PASS`, `AUTHENTIK_SECRET_KEY`;
      Papra `AUTH_SECRET`; Checkmate `ENCRYPTION_KEY`, `CAPTURE_API_SECRET`.
      Do not let `stack init` replace them.
- [ ] Generate a new Checkmate `JWT_SECRET` with `openssl rand -hex 32`; do not
      reuse the exposed JWT secret.
- [ ] Rotate only the Papra OIDC client secret in Authentik immediately before
      the Papra swap, keep `AUTH_SECRET` so existing sessions stay valid, and put
      the new URL-safe value in `papra/.secrets`; do not reuse the exposed
      secret.
- [ ] If any other existing secret is empty, generate one with
      `openssl rand -hex 32`; otherwise `stack check` rejects the empty secret.
- [ ] Set `IMMICH_UPLOAD_LOCATION` to the old `UPLOAD_LOCATION` path.
- [ ] `chmod 600` every `*/.secrets` file.
- [ ] Set `DATA_ROOT=/home/layz`, `BASE_DOMAIN=priyav.dev`, and
      `ENABLED_SERVICES=jellyfin,immich,tandoor,authentik,papra,checkmate` so
      all six migrated services are enabled.
- [ ] Run `./stack init` and `./stack check` on the server.
- [ ] Copy `jellyfin/compose.override.yaml.example` to
      `jellyfin/compose.override.yaml` for `/dev/dri` with `cp -n`, so an
      existing host override is not overwritten.
- [ ] Copy `checkmate/compose.override.yaml.example` to
      `checkmate/compose.override.yaml` with `cp -n` if group 957 owns the
      Docker socket.
- [ ] For each service, migrate only that service's volumes using the matching
      stop and copy pair in section 4, immediately before the swap. Do not stop
      all four volume owners at once; stopping Authentik early breaks Papra OIDC
      logins.
- [ ] Complete the soft-swap for every service and verify each public URL
      through nginx. Also run the staging Traefik with `-p traefik-staging`,
      `traefik/compose.staging.yaml`, and a separate `acme-staging.json`; remove
      both staging files when done.
- [ ] Do not stop an old project after its new project is running; both use the
      same project name, so `docker compose down` would remove the new
      containers.
- [ ] Roll back with nginx and all six old services, using the `.yml`/`.yaml`
      fallback. Post-swap writes to the new binds are lost on rollback; copy
      them back into the old volumes first if needed.
- [ ] Keep nginx running. Leave the old volumes in place as the rollback copy;
      do not delete them until verification.
- [ ] Do not run `./stack down -v`.

## Definition of done

- `git status` is clean except for any pre-existing untracked local directory.
- `shellcheck stack tests/*.sh tools/*.sh` passes.
- Every test script prints its `passed` line.
- All five services render with `BASE_DOMAIN=example.test`.
- No rendered mount has `"type": "volume"`.
- No tracked secrets. Production domains may appear in the reference runbook and
  DNS tooling, but not in rendered compose or service env/test files.
- `v0.2.0` exists.
- Production nginx is still running; no ingress cutover has happened.

---

## Self-review

- **Spec coverage:** service directories (Tasks 3-7), root and per-service env
  (Tasks 3-7), Traefik labels and loopback ports (Tasks 3-7), external
  bind-mounted data (Tasks 1-2, 9), data-safety guardrails (Tasks 3-8), tests
  (Tasks 1-8), docs (Task 9), release tag (Task 10).
- **Placeholders:** none; every code step contains complete content.
- **Consistency:** `render_service`, `render_service_json`, `install_fixture`,
  `assert_no_volumes`, `$DATA_ROOT`, and the service names match across tasks.
- **Deliberate gap:** the actual nginx-to-Traefik cutover stays in Phase 3 so
  unmigrated or inactive hosts cannot take production offline.






