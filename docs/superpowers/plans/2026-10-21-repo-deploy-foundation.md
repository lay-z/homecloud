# Repo Deployment Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the reusable repo foundation and migrate Jellyfin to it, without cutting production ingress over yet.

**Architecture:** Each service is a top-level directory containing `compose.yaml`, a gitignored `.env`, and a gitignored `.secrets`. A root `.env` holds instance-wide values, and all persistent data lives under `${DATA_ROOT}/<service>`, outside the clone. A small bash `stack` wrapper starts Traefik first, then enabled services.

**Tech Stack:** Bash, Docker Compose v2, Traefik v3, Jellyfin, GitHub Actions.

---

## Program phases

| Phase | Scope | Status |
| --- | --- | --- |
| 1 | Repo foundation, `stack`, Traefik, Jellyfin conversion, tests, docs | This plan |
| 2 | Convert Immich, Tandoor, Authentik, Papra, and Checkmate | Follow-on plan |
| 3 | Cut production ingress from nginx to Traefik, add update timer | Follow-on plan |

Do not stop the production nginx container in this plan. Doing so would take every unmigrated domain offline.

## Scope

In scope:

- Initialize this directory as a git repository.
- Add `.gitignore`, root `.env.example`, and per-service env templates.
- Implement `./stack init`, `check`, `up`, `down`, `status`, `logs`, `restart`, `update`, and `doctor`.
- Add Traefik with direct Docker socket access (no proxy in v1).
- Convert Jellyfin into `jellyfin/` while preserving its data paths.
- Add shell and compose-render tests plus CI.
- Document installation, operations, and the eventual adoption runbook.
- Tag `v0.1.0`.

Out of scope:

- Migrating the remaining services.
- Stopping nginx or changing production DNS.
- Automatic updates.
- Domain changes after install.
- Socket proxies, rootless runtimes, or rootless Podman/Quadlet.

## File structure

```text
.
├── .github/workflows/ci.yml
├── .gitignore
├── .env.example
├── stack
├── traefik/
│   └── compose.yaml
├── jellyfin/
│   ├── compose.yaml
│   ├── compose.override.yaml.example
│   ├── .env.example
│   ├── .env
│   ├── .secrets.example
│   └── .secrets
├── tests/
│   ├── lib.sh
│   ├── init_test.sh
│   ├── check_test.sh
│   ├── lifecycle_test.sh
│   ├── update_test.sh
│   ├── compose_render_test.sh
│   └── data_safety_test.sh
├── docs/
│   ├── install.md
│   ├── operations.md
│   ├── adopt-existing-server.md
│   └── superpowers/
│       ├── specs/2026-10-21-repo-deploy-architecture-design.md
│       └── plans/2026-10-21-repo-deploy-foundation.md
├── tools/dns/
│   ├── namecheap_dns.py
│   └── README.md
├── README.md
└── AGENTS.md
```

Responsibilities:

- `stack`: the only operator interface; no business logic in compose files beyond interpolation.
- `traefik/compose.yaml`: ingress, TLS, and Docker provider.
- `<service>/compose.yaml`: one service stack per file, explicit `name:`, no hardcoded domains or secrets.
- Root `.env`: instance values used by `stack` and Compose interpolation.
- `<service>/.env` and `<service>/.secrets`: service-local values; both gitignored.
- `${DATA_ROOT}/<service>`: persistent data, never inside the repo.
- `tests/`: fast tests that do not require a running Docker daemon, plus a compose render test.

---

### Task 1: Initialize git and protect local files

**Files:**
- Create: `.gitignore`
- Modify: none

- [ ] **Step 1: Initialize the repository**

Run:

```bash
git init -b main
```

Expected: `Initialized empty Git repository ...`

- [ ] **Step 2: Create `.gitignore`**

Create `.gitignore` with exactly:

```gitignore
.env
*/.env
*/.secrets
*/compose.override.yaml
.namecheap.env
*.bak
*.log
__pycache__/
```

- [ ] **Step 3: Verify local files are ignored**

Run:

```bash
git status --short
git check-ignore -v .namecheap.env
```

Expected: `.namecheap.env` does not appear in `git status`; `git check-ignore` prints the matching rule.

- [ ] **Step 4: Commit the existing design and tooling**

Run:

```bash
git add .gitignore README.md AGENTS.md namecheap_dns.py docs
git status --short
git commit -m "chore: initialize stack repository"
```

Expected: commit succeeds and `.namecheap.env` is not included.

---

### Task 2: Add the instance env template

**Files:**
- Create: `.env.example`

- [ ] **Step 1: Write `.env.example`**

Create `.env.example` with exactly:

```dotenv
# Base domain without a scheme, path, or trailing slash.
BASE_DOMAIN=example.com

# Let's Encrypt account email.
ACME_EMAIL=admin@example.com

# Root directory for persistent service data. Must be outside this repo.
DATA_ROOT=/srv/stack

# Timezone.
TZ=UTC

# UID/GID for services that support it.
PUID=1000
PGID=1000

# Comma-separated service names. Traefik is always started.
ENABLED_SERVICES=jellyfin
```

- [ ] **Step 2: Verify no secrets are present**

Run:

```bash
git diff -- .env.example
```

Expected: only the placeholder values above, no real credentials.

- [ ] **Step 3: Commit**

```bash
git add .env.example
git commit -m "feat: add instance env template"
```

---

### Task 3: Implement `stack init`

**Files:**
- Create: `stack`
- Create: `tests/lib.sh`
- Create: `tests/init_test.sh`

- [ ] **Step 1: Write the shared test helper**

Create `tests/lib.sh` with exactly:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export PATH="$TMP/bin:$PATH"
export DOCKER_LOG="$TMP/docker.log"
mkdir -p "$TMP/bin"

cat > "$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
if [[ "${DOCKER_VOLUME_JSON:-0}" == "1" && "$*" == *"config --format json"* ]]; then
  printf '{"services":{"x":{"volumes":[{"type":"volume"}]}}}\n'
fi
exit 0
FAKE
chmod +x "$TMP/bin/docker"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

make_repo() {
  local dir="$1"
  mkdir -p "$dir/traefik" "$dir/jellyfin"
  cp "$ROOT/stack" "$dir/stack"
  cp "$ROOT/.env.example" "$dir/.env.example"
  cp "$ROOT/.gitignore" "$dir/.gitignore"
  chmod +x "$dir/stack"

  cat > "$dir/traefik/compose.yaml" <<'YAML'
name: traefik
services:
  traefik:
    image: traefik
YAML

  cat > "$dir/jellyfin/compose.yaml" <<'YAML'
name: jellyfin
services:
  jellyfin:
    image: jellyfin
YAML

  cat > "$dir/jellyfin/.env.example" <<'ENV'
JELLYFIN_MEDIA_PATH=/tmp/media
ENV

  cat > "$dir/jellyfin/.secrets.example" <<'SECRETS'
JELLYFIN_SECRET=
SECRETS
}
```

- [ ] **Step 2: Write the failing init test**

Create `tests/init_test.sh` with exactly:

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

repo="$TMP/repo"
make_repo "$repo"

"$repo/stack" init >/dev/null

assert_file "$repo/.env"
assert_file "$repo/jellyfin/.env"
assert_file "$repo/jellyfin/.secrets"
assert_eq "$(stat -c %a "$repo/jellyfin/.secrets")" "600"
assert_contains "$repo/jellyfin/.secrets" "JELLYFIN_SECRET="

sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$TMP/data|" "$repo/.env"
printf '\n# keep me\n' >> "$repo/.env"

"$repo/stack" init >/dev/null

assert_contains "$repo/.env" "# keep me"
assert_file "$TMP/data/traefik/acme.json"
assert_eq "$(stat -c %a "$TMP/data/traefik/acme.json")" "600"
assert_file "$TMP/data/jellyfin/config"
assert_file "$TMP/data/jellyfin/cache"

printf 'init tests passed\n'
```

- [ ] **Step 3: Make tests executable and run them to verify failure**

Run:

```bash
chmod +x tests/init_test.sh
./tests/init_test.sh
```

Expected: FAIL because `stack` does not exist.

- [ ] **Step 4: Write the `stack` skeleton and init command**

Create `stack` with exactly:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="${STACK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

die() {
  printf 'stack: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

load_env() {
  # shellcheck disable=SC1091
  set -a
  . "$ROOT/.env"
  set +a
}

enabled_services() {
  local raw="${ENABLED_SERVICES// /}"
  local -a services
  local svc

  IFS=',' read -ra services <<< "$raw"
  for svc in "${services[@]}"; do
    if [[ -n "$svc" ]]; then
      printf '%s\n' "$svc"
    fi
  done
}

generate_service_secrets() {
  local dir="$1"
  local example="$dir/.secrets.example"
  local target="$dir/.secrets"
  local old_umask line key

  [[ -f "$example" ]] || return 0

  if [[ ! -f "$target" ]]; then
    old_umask="$(umask)"
    umask 077
    : > "$target"

    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
      key="${BASH_REMATCH[1]}"
      printf '%s=%s\n' "$key" "$(openssl rand -hex 32)" >> "$target"
    done < "$example"

    umask "$old_umask"
  fi

  chmod 600 "$target"
}

cmd_init() {
  local created_env=0
  local dir svc

  if [[ ! -f "$ROOT/.env" ]]; then
    cp "$ROOT/.env.example" "$ROOT/.env"
    created_env=1
  fi

  for dir in "$ROOT"/*/; do
    [[ -f "$dir/.env.example" ]] || continue
    if [[ ! -f "$dir/.env" ]]; then
      cp "$dir/.env.example" "$dir/.env"
    fi
    generate_service_secrets "$dir"
  done

  if (( created_env )); then
    info "created .env"
    info "edit BASE_DOMAIN, ACME_EMAIL, DATA_ROOT, and ENABLED_SERVICES, then rerun ./stack init"
    return 0
  fi

  load_env

  mkdir -p "$DATA_ROOT/traefik"

  if [[ ! -f "$DATA_ROOT/traefik/acme.json" ]]; then
    : > "$DATA_ROOT/traefik/acme.json"
    chmod 600 "$DATA_ROOT/traefik/acme.json"
  fi

  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    case "$svc" in
      jellyfin)
        mkdir -p "$DATA_ROOT/jellyfin/config" "$DATA_ROOT/jellyfin/cache"
        ;;
      *)
        mkdir -p "$DATA_ROOT/$svc"
        ;;
    esac
  done <<< "$(enabled_services)"

  info "initialized $BASE_DOMAIN"
  info "required DNS: *.${BASE_DOMAIN} -> this host"
}

cmd_help() {
  cat <<'EOF'
Usage: ./stack <command>

Commands:
  init                 Create env files and required directories
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    init) cmd_init "$@";;
    help|-h|--help) cmd_help;;
    *) die "unknown command: $cmd (try ./stack help)";;
  esac
}

main "$@"
```

- [ ] **Step 5: Make the script executable and run the test**

Run:

```bash
chmod +x stack
./tests/init_test.sh
```

Expected: `init tests passed`.

- [ ] **Step 6: Commit**

```bash
git add stack tests/lib.sh tests/init_test.sh
git commit -m "feat: add stack init command"
```

---

### Task 4: Implement `stack check`

**Files:**
- Modify: `stack`
- Create: `tests/check_test.sh`

- [ ] **Step 1: Write the failing check test**

Create `tests/check_test.sh` with exactly:

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

repo="$TMP/repo"
make_repo "$repo"
cp "$repo/.env.example" "$repo/.env"
sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$TMP/data|" "$repo/.env"
"$repo/stack" init >/dev/null

"$repo/stack" check >/dev/null

cp "$repo/.env" "$repo/.env.good"
sed -i 's|^BASE_DOMAIN=.*|BASE_DOMAIN=https://bad|' "$repo/.env"
if "$repo/stack" check >/dev/null 2>&1; then
  fail "check accepted a base domain with a scheme"
fi
mv "$repo/.env.good" "$repo/.env"

mv "$repo/jellyfin/.env" "$repo/jellyfin/.env.bak"
if "$repo/stack" check >/dev/null 2>&1; then
  fail "check accepted a missing service .env"
fi
mv "$repo/jellyfin/.env.bak" "$repo/jellyfin/.env"

mv "$repo/jellyfin/.secrets" "$repo/jellyfin/.secrets.bak"
if "$repo/stack" check >/dev/null 2>&1; then
  fail "check accepted a missing service .secrets"
fi
mv "$repo/jellyfin/.secrets.bak" "$repo/jellyfin/.secrets"

printf '\nBASE_DOMAIN=bad.example\n' >> "$repo/jellyfin/.env"
if "$repo/stack" check >/dev/null 2>&1; then
  fail "check accepted a reserved key in a service env"
fi
sed -i '/^BASE_DOMAIN=bad.example$/d' "$repo/jellyfin/.env"

if DOCKER_VOLUME_JSON=1 "$repo/stack" check >/dev/null 2>&1; then
  fail "check accepted a named volume"
fi

: > "$DOCKER_LOG"
"$repo/stack" check >/dev/null

assert_contains "$DOCKER_LOG" "--env-file $repo/.env"
assert_contains "$DOCKER_LOG" "--env-file $repo/jellyfin/.env"
assert_contains "$DOCKER_LOG" "--env-file $repo/jellyfin/.secrets"
assert_contains "$DOCKER_LOG" "jellyfin/compose.yaml config -q"
assert_contains "$DOCKER_LOG" "traefik/compose.yaml config -q"

printf 'check tests passed\n'
```

- [ ] **Step 2: Run the test to verify failure**

Run:

```bash
chmod +x tests/check_test.sh
./tests/check_test.sh
```

Expected: FAIL because `check` is not implemented.

- [ ] **Step 3: Add validation helpers and the check command**

Add these functions to `stack`, after `load_env`:

```bash
require_file() {
  [[ -f "$ROOT/$1" ]] || die "missing $1"
}

valid_domain() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

check_reserved() {
  local file="$1"
  if grep -Eq '^(BASE_DOMAIN|ACME_EMAIL|DATA_ROOT|ENABLED_SERVICES)=' "$file"; then
    die "reserved instance key in ${file#"$ROOT"/}"
  fi
}

check_service_secrets() {
  local dir="$1"
  local example="$dir/.secrets.example"
  local target="$dir/.secrets"
  local line key value

  [[ -f "$example" ]] || return 0
  [[ -f "$target" ]] || die "missing ${target#"$ROOT"/}"
  [[ "$(stat -c %a "$target")" == "600" ]] || die "${target#"$ROOT"/} must be mode 600"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
    key="${BASH_REMATCH[1]}"
    value="$(grep -E "^${key}=" "$target" | tail -n1 | cut -d= -f2- || true)"
    [[ -n "$value" ]] || die "empty secret $key in ${target#"$ROOT"/}"
  done < "$example"
}

compose() {
  local service="$1"
  shift
  local dir="$ROOT/$service"
  local args=(-f "$dir/compose.yaml")
  local env_args=(--env-file "$ROOT/.env")

  [[ -d "$dir" ]] || die "unknown service: $service"

  if [[ -f "$dir/compose.override.yaml" ]]; then
    args+=(-f "$dir/compose.override.yaml")
  fi
  if [[ -f "$dir/.env" ]]; then
    env_args+=(--env-file "$dir/.env")
  fi
  if [[ -f "$dir/.secrets" ]]; then
    env_args+=(--env-file "$dir/.secrets")
  fi

  (
    cd "$dir"
    "$DOCKER_BIN" compose "${env_args[@]}" "${args[@]}" "$@"
  )
}

check_data_safety() {
  local service="$1"
  local rendered

  rendered="$(compose "$service" config --format json)"

  if grep -Eq '"type"[[:space:]]*:[[:space:]]*"volume"' <<< "$rendered"; then
    die "$service uses a named or anonymous volume; use a bind mount under DATA_ROOT"
  fi
}

cmd_check() {
  require_file ".env"
  load_env

  [[ -n "${BASE_DOMAIN:-}" ]] || die "BASE_DOMAIN is required"
  [[ -n "${ACME_EMAIL:-}" ]] || die "ACME_EMAIL is required"
  [[ -n "${DATA_ROOT:-}" ]] || die "DATA_ROOT is required"
  [[ -n "${ENABLED_SERVICES:-}" ]] || die "ENABLED_SERVICES is required"

  valid_domain "$BASE_DOMAIN" || die "BASE_DOMAIN must be a bare domain: $BASE_DOMAIN"
  [[ "$ACME_EMAIL" == *@*.* ]] || die "ACME_EMAIL is not valid: $ACME_EMAIL"
  [[ "$DATA_ROOT" == /* ]] || die "DATA_ROOT must be absolute: $DATA_ROOT"
  [[ -d "$DATA_ROOT" ]] || die "DATA_ROOT does not exist: $DATA_ROOT"
  [[ -f "$DATA_ROOT/traefik/acme.json" ]] || die "missing $DATA_ROOT/traefik/acme.json (run ./stack init)"

  local services svc dir
  services="$(enabled_services)"
  [[ -n "$services" ]] || die "ENABLED_SERVICES is empty"

  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    dir="$ROOT/$svc"
    [[ -d "$dir" ]] || die "unknown service: $svc"
    [[ -f "$dir/compose.yaml" ]] || die "missing $svc/compose.yaml"
    [[ -f "$dir/.env" ]] || die "missing $svc/.env"
    [[ -d "$DATA_ROOT/$svc" ]] || die "missing data directory: $DATA_ROOT/$svc"

    check_reserved "$dir/.env"
    if [[ -f "$dir/.secrets" ]]; then
      check_reserved "$dir/.secrets"
    fi
    check_service_secrets "$dir"
    compose "$svc" config -q
    check_data_safety "$svc"
  done <<< "$services"

  compose traefik config -q
  check_data_safety traefik

  local file
  while IFS= read -r file; do
    if grep -n "$BASE_DOMAIN" "$file" >/dev/null 2>&1; then
      die "found hardcoded base domain in ${file#"$ROOT"/}"
    fi
  done < <(find "$ROOT" -maxdepth 2 -type f \( -name 'compose.yaml' -o -name 'stack' \) ! -path '*/.git/*')

  info "check passed for $BASE_DOMAIN"
}
```

- [ ] **Step 4: Register the command**

In `main`, add this case before `init`:

```bash
    check) cmd_check "$@";;
```

- [ ] **Step 5: Run the tests**

Run:

```bash
./tests/init_test.sh
./tests/check_test.sh
```

Expected:

```text
init tests passed
check tests passed
```

- [ ] **Step 6: Commit**

```bash
git add stack tests/check_test.sh
git commit -m "feat: add stack check command"
```

---

### Task 5: Implement lifecycle commands

**Files:**
- Modify: `stack`
- Create: `tests/lifecycle_test.sh`

- [ ] **Step 1: Write the failing lifecycle test**

Create `tests/lifecycle_test.sh` with exactly:

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

repo="$TMP/repo"
make_repo "$repo"
cp "$repo/.env.example" "$repo/.env"
sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$TMP/data|" "$repo/.env"
"$repo/stack" init >/dev/null

: > "$DOCKER_LOG"
"$repo/stack" up >/dev/null

mapfile -t ups < <(grep ' up -d' "$DOCKER_LOG")
[[ "${#ups[@]}" -ge 2 ]] || fail "expected Traefik and Jellyfin up calls"
[[ "${ups[0]}" == *"traefik/compose.yaml"* ]] || fail "Traefik was not started first"
[[ "${ups[1]}" == *"jellyfin/compose.yaml"* ]] || fail "Jellyfin was not started second"

printf 'services:\n' > "$repo/jellyfin/compose.override.yaml"
: > "$DOCKER_LOG"
"$repo/stack" up >/dev/null
assert_contains "$DOCKER_LOG" "jellyfin/compose.override.yaml"

if "$repo/stack" down -v >/dev/null 2>&1; then
  fail "down accepted -v"
fi

: > "$DOCKER_LOG"
"$repo/stack" down >/dev/null
assert_contains "$DOCKER_LOG" "jellyfin/compose.yaml down"
assert_contains "$DOCKER_LOG" "traefik/compose.yaml down"
if grep -q -- ' -v' "$DOCKER_LOG"; then
  fail "down used -v"
fi

printf 'lifecycle tests passed\n'
```

- [ ] **Step 2: Run the test to verify failure**

```bash
chmod +x tests/lifecycle_test.sh
./tests/lifecycle_test.sh
```

Expected: FAIL because `up` is not implemented.

- [ ] **Step 3: Add lifecycle commands to `stack`**

Add these functions after `cmd_check`:

```bash
cmd_up() {
  cmd_check
  load_env

  compose traefik up -d --remove-orphans

  local svc
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    info "starting $svc"
    compose "$svc" up -d --remove-orphans
  done <<< "$(enabled_services)"

  info "done"
}

cmd_down() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--volumes)
        die "refusing to remove volumes; persistent data lives under DATA_ROOT"
        ;;
      *)
        die "unknown down option: $1"
        ;;
    esac
  done

  load_env

  local svc
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    compose "$svc" down
  done <<< "$(enabled_services)"

  compose traefik down
}

cmd_status() {
  load_env
  compose traefik ps

  local svc
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    compose "$svc" ps
  done <<< "$(enabled_services)"
}

cmd_logs() {
  local svc="${1:-}"
  [[ -n "$svc" ]] || die "usage: ./stack logs <service>"
  [[ -d "$ROOT/$svc" ]] || die "unknown service: $svc"
  compose "$svc" logs -f --tail=100
}

cmd_restart() {
  local svc="${1:-}"
  [[ -n "$svc" ]] || die "usage: ./stack restart <service>"
  [[ -d "$ROOT/$svc" ]] || die "unknown service: $svc"
  compose "$svc" restart
}
```

- [ ] **Step 4: Register the commands**

In `main`, add these cases before `init`:

```bash
    up) cmd_up "$@";;
    down) cmd_down "$@";;
    status) cmd_status "$@";;
    logs) cmd_logs "$@";;
    restart) cmd_restart "$@";;
```

- [ ] **Step 5: Update help output**

Replace `cmd_help` with:

```bash
cmd_help() {
  cat <<'EOF'
Usage: ./stack <command>

Commands:
  init                 Create env files and required directories
  check                Validate env files and compose configuration
  up                   Start Traefik and enabled services
  down                 Stop enabled services and Traefik (keeps data)
  status               Show container status
  logs <service>       Follow logs for a service
  restart <service>    Restart a service
EOF
}
```

- [ ] **Step 6: Run the tests**

```bash
./tests/init_test.sh
./tests/check_test.sh
./tests/lifecycle_test.sh
```

Expected:

```text
init tests passed
check tests passed
lifecycle tests passed
```

- [ ] **Step 7: Commit**

```bash
git add stack tests/lifecycle_test.sh
git commit -m "feat: add stack lifecycle commands"
```

---

### Task 6: Implement `stack update` and `doctor`

**Files:**
- Modify: `stack`
- Create: `tests/update_test.sh`

- [ ] **Step 1: Write the failing update test**

Create `tests/update_test.sh` with exactly:

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

repo="$TMP/repo"
make_repo "$repo"
cp "$repo/.env.example" "$repo/.env"
sed -i "s|^DATA_ROOT=.*|DATA_ROOT=$TMP/data|" "$repo/.env"
"$repo/stack" init >/dev/null

git -C "$repo" init -q
git -C "$repo" config user.email "test@example.test"
git -C "$repo" config user.name "Test"
git -C "$repo" add -A
git -C "$repo" commit -qm "initial"
git -C "$repo" tag v0.1.0

git init --bare -q "$TMP/remote.git"
git -C "$repo" remote add origin "$TMP/remote.git"
git -C "$repo" push -qu origin HEAD --tags

printf '\n# dirty\n' >> "$repo/stack"
if "$repo/stack" update >/dev/null 2>&1; then
  fail "update accepted a dirty tracked tree"
fi
git -C "$repo" checkout -- stack

: > "$DOCKER_LOG"
"$repo/stack" update >/dev/null
assert_contains "$DOCKER_LOG" "traefik/compose.yaml up -d"

printf 'JELLYFIN_SECRET=supersecret\n' >> "$repo/jellyfin/.secrets"
doctor="$("$repo/stack" doctor)"
[[ "$doctor" != *"supersecret"* ]] || fail "doctor leaked a secret value"
[[ "$doctor" == *"JELLYFIN_SECRET"* ]] || fail "doctor did not list secret keys"

printf 'update tests passed\n'
```

- [ ] **Step 2: Run the test to verify failure**

```bash
chmod +x tests/update_test.sh
./tests/update_test.sh
```

Expected: FAIL because `update` is not implemented.

- [ ] **Step 3: Add update and doctor commands**

Add these functions after `cmd_restart`:

```bash
cmd_update() {
  local target=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [[ $# -ge 2 ]] || die "--version requires a value"
        target="$2"
        shift 2
        ;;
      *)
        die "unknown update option: $1"
        ;;
    esac
  done

  git -C "$ROOT" diff --quiet || die "tracked files are modified; commit or stash first"
  git -C "$ROOT" diff --cached --quiet || die "staged changes present; commit or stash first"

  local previous
  previous="$(git -C "$ROOT" describe --tags --always)"
  git -C "$ROOT" fetch --tags --prune

  if [[ -z "$target" ]]; then
    target="$(git -C "$ROOT" tag -l 'v*' --sort=-v:refname | head -n1)"
  fi
  [[ -n "$target" ]] || die "no release tag found"

  git -C "$ROOT" checkout "$target"
  info "updating from $previous to $target"
  cmd_up
}

read_env_value() {
  local key="$1"
  local default="$2"
  local value

  value="$(grep -E "^${key}=" "$ROOT/.env" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  printf '%s' "${value:-$default}"
}

cmd_doctor() {
  local base_domain="unset"
  local data_root="/"
  local dir

  if [[ -f "$ROOT/.env" ]]; then
    base_domain="$(read_env_value BASE_DOMAIN unset)"
    data_root="$(read_env_value DATA_ROOT /)"
  fi

  info "repo: $ROOT"
  info "base domain: $base_domain"
  "$DOCKER_BIN" --version || true
  "$DOCKER_BIN" compose version || true
  git --version || true
  df -h "$data_root" || true

  for dir in "$ROOT"/*/; do
    [[ -f "$dir/.secrets" ]] || continue
    info "$(basename "$dir") secret keys:"
    sed -n 's/=.*//p' "$dir/.secrets" | sed 's/^/  /'
  done
}
```

- [ ] **Step 4: Register the commands**

In `main`, add these cases before `init`:

```bash
    update) cmd_update "$@";;
    doctor) cmd_doctor "$@";;
```

- [ ] **Step 5: Update help output**

Add these lines to `cmd_help` before `EOF`:

```text
  update [--version v] Check out a release tag and redeploy
  doctor               Print redacted diagnostics
```

- [ ] **Step 6: Run all stack tests**

```bash
./tests/init_test.sh
./tests/check_test.sh
./tests/lifecycle_test.sh
./tests/update_test.sh
```

Expected:

```text
init tests passed
check tests passed
lifecycle tests passed
update tests passed
```

- [ ] **Step 7: Commit**

```bash
git add stack tests/update_test.sh
git commit -m "feat: add stack update and doctor commands"
```

---

### Task 7: Add Traefik

**Files:**
- Create: `traefik/compose.yaml`
- Create: `tests/compose_render_test.sh`

- [ ] **Step 1: Write the failing compose render test**

Create `tests/compose_render_test.sh` with exactly:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/.env" <<EOF
BASE_DOMAIN=example.test
ACME_EMAIL=admin@example.test
DATA_ROOT=$TMP/data
TZ=UTC
PUID=1000
PGID=1000
ENABLED_SERVICES=jellyfin
EOF

cp -a "$ROOT/traefik" "$TMP/traefik"

traefik="$(docker compose --env-file "$TMP/.env" -f "$TMP/traefik/compose.yaml" config)"

grep -Fq 'certificatesresolvers.le.acme.email=admin@example.test' <<< "$traefik" \
  || { printf 'FAIL: Traefik ACME email missing\n' >&2; exit 1; }
grep -Fq 'entrypoints.websecure.address=:443' <<< "$traefik" \
  || { printf 'FAIL: Traefik websecure entrypoint missing\n' >&2; exit 1; }
grep -Fq 'providers.docker.exposedByDefault=false' <<< "$traefik" \
  || { printf 'FAIL: Traefik exposedByDefault missing\n' >&2; exit 1; }
grep -Fq '/acme.json' <<< "$traefik" \
  || { printf 'FAIL: Traefik acme.json mount missing\n' >&2; exit 1; }

printf 'compose render tests passed\n'
```

- [ ] **Step 2: Run it to verify failure**

```bash
chmod +x tests/compose_render_test.sh
./tests/compose_render_test.sh
```

Expected: FAIL because `traefik/compose.yaml` does not exist.

- [ ] **Step 3: Write the Traefik compose file**

Create `traefik/compose.yaml` with exactly:

```yaml
name: traefik

services:
  traefik:
    image: traefik:v3.5.0
    container_name: traefik
    restart: unless-stopped
    network_mode: host
    command:
      - --global.checkNewVersion=false
      - --global.sendAnonymousUsage=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --providers.docker=true
      - --providers.docker.exposedByDefault=false
      - --providers.docker.endpoint=unix:///var/run/docker.sock
      - --certificatesresolvers.le.acme.email=${ACME_EMAIL}
      - --certificatesresolvers.le.acme.storage=/acme.json
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
      - --api.dashboard=false
      - --log.level=INFO
      - --accesslog=false
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${DATA_ROOT}/traefik/acme.json:/acme.json
```

- [ ] **Step 4: Run the render test**

```bash
./tests/compose_render_test.sh
```

Expected: `compose render tests passed`.

- [ ] **Step 5: Commit**

```bash
git add traefik/compose.yaml tests/compose_render_test.sh
git commit -m "feat: add Traefik ingress"
```

---

### Task 8: Convert Jellyfin

**Files:**
- Create: `jellyfin/compose.yaml`
- Create: `jellyfin/.env.example`
- Create: `jellyfin/.secrets.example`
- Create: `jellyfin/compose.override.yaml.example`
- Modify: `tests/compose_render_test.sh`

- [ ] **Step 1: Extend the render test with Jellyfin assertions**

In `tests/compose_render_test.sh`, replace the final line:

```bash
printf 'compose render tests passed\n'
```

with:

```bash
cp -a "$ROOT/jellyfin" "$TMP/jellyfin"

cat > "$TMP/jellyfin/.env" <<EOF
JELLYFIN_MEDIA_PATH=$TMP/media
EOF
: > "$TMP/jellyfin/.secrets"

jellyfin="$(docker compose \
  --env-file "$TMP/.env" \
  --env-file "$TMP/jellyfin/.env" \
  --env-file "$TMP/jellyfin/.secrets" \
  -f "$TMP/jellyfin/compose.yaml" \
  config)"

grep -Fq 'name: jellyfin' <<< "$jellyfin" \
  || { printf 'FAIL: Jellyfin project name missing\n' >&2; exit 1; }
grep -Fq 'Host(`flix.example.test`)' <<< "$jellyfin" \
  || { printf 'FAIL: Jellyfin host rule missing\n' >&2; exit 1; }
grep -Fq 'https://flix.example.test' <<< "$jellyfin" \
  || { printf 'FAIL: Jellyfin published URL missing\n' >&2; exit 1; }
grep -Fq 'http://127.0.0.1:8096' <<< "$jellyfin" \
  || { printf 'FAIL: Jellyfin upstream missing\n' >&2; exit 1; }
grep -Fq 'host_ip: 127.0.0.1' <<< "$jellyfin" \
  || { printf 'FAIL: Jellyfin port is not loopback-bound\n' >&2; exit 1; }
grep -Fq "${TMP}/data/jellyfin/config" <<< "$jellyfin" \
  || { printf 'FAIL: Jellyfin config mount missing\n' >&2; exit 1; }

if grep -Fq 'priyav.dev' <<< "$traefik$jellyfin"; then
  printf 'FAIL: production domain leaked into rendered compose\n' >&2
  exit 1
fi

printf 'compose render tests passed\n'
```

- [ ] **Step 2: Run it to verify failure**

```bash
./tests/compose_render_test.sh
```

Expected: FAIL because `jellyfin/compose.yaml` does not exist.

- [ ] **Step 3: Write the Jellyfin env templates**

Create `jellyfin/.env.example` with exactly:

```dotenv
# Media library path on the host.
JELLYFIN_MEDIA_PATH=/srv/media
```

Create `jellyfin/.secrets.example` with exactly:

```dotenv
# Jellyfin needs no secrets. Keep the empty file so the env contract is uniform.
```

- [ ] **Step 4: Write the Jellyfin compose file**

Create `jellyfin/compose.yaml` with exactly:

```yaml
name: jellyfin

services:
  jellyfin:
    image: jellyfin/jellyfin:10.10.7
    container_name: jellyfin
    restart: unless-stopped
    user: "${PUID:-1000}:${PGID:-1000}"
    env_file:
      - .env
      - .secrets
    ports:
      - "127.0.0.1:8096:8096"
    volumes:
      - ${DATA_ROOT}/jellyfin/config:/config
      - ${DATA_ROOT}/jellyfin/cache:/cache
      - ${JELLYFIN_MEDIA_PATH}:/media
    environment:
      JELLYFIN_PublishedServerUrl: https://flix.${BASE_DOMAIN}
      TZ: ${TZ}
    labels:
      - traefik.enable=true
      - traefik.http.routers.flix.rule=Host(`flix.${BASE_DOMAIN}`)
      - traefik.http.routers.flix.entrypoints=websecure
      - traefik.http.routers.flix.tls.certresolver=le
      - traefik.http.routers.flix.middlewares=jellyfin-headers,jellyfin-buffering
      - traefik.http.services.flix.loadbalancer.server.url=http://127.0.0.1:8096
      - traefik.http.middlewares.jellyfin-headers.headers.customresponseheaders.X-Content-Type-Options=nosniff
      - "traefik.http.middlewares.jellyfin-headers.headers.customresponseheaders.Content-Security-Policy=default-src https: data: blob: ; img-src 'self' https://* ; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' https://www.gstatic.com https://www.youtube.com blob:; worker-src 'self' blob:; connect-src 'self'; object-src 'none'; font-src 'self'"
      - traefik.http.middlewares.jellyfin-buffering.buffering.maxRequestBodyBytes=20971520
```

- [ ] **Step 5: Add the hardware-transcoding override example**

Create `jellyfin/compose.override.yaml.example` with exactly:

```yaml
services:
  jellyfin:
    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128
```

The real `jellyfin/compose.override.yaml` is gitignored and is for host-only hardware settings.

- [ ] **Step 6: Run the render test**

```bash
./tests/compose_render_test.sh
```

Expected: `compose render tests passed`.

- [ ] **Step 7: Add the data safety test**

Create `tests/data_safety_test.sh` with exactly:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/.env" <<EOF
BASE_DOMAIN=example.test
ACME_EMAIL=admin@example.test
DATA_ROOT=$TMP/data
TZ=UTC
PUID=1000
PGID=1000
ENABLED_SERVICES=jellyfin
EOF

cp -a "$ROOT/traefik" "$TMP/traefik"
cp -a "$ROOT/jellyfin" "$TMP/jellyfin"

cat > "$TMP/jellyfin/.env" <<EOF
JELLYFIN_MEDIA_PATH=$TMP/media
EOF
: > "$TMP/jellyfin/.secrets"

render() {
  local service="$1"
  local args=(--env-file "$TMP/.env" -f "$TMP/$service/compose.yaml")

  if [[ -f "$TMP/$service/.env" ]]; then
    args+=(--env-file "$TMP/$service/.env")
  fi
  if [[ -f "$TMP/$service/.secrets" ]]; then
    args+=(--env-file "$TMP/$service/.secrets")
  fi

  docker compose "${args[@]}" config --format json
}

for service in traefik jellyfin; do
  rendered="$(render "$service")"
  if grep -Eq '"type"[[:space:]]*:[[:space:]]*"volume"' <<< "$rendered"; then
    printf 'FAIL: %s has a named or anonymous volume\n' "$service" >&2
    exit 1
  fi
done

printf 'data safety tests passed\n'
```

- [ ] **Step 8: Run all tests**

```bash
./tests/init_test.sh
./tests/check_test.sh
./tests/lifecycle_test.sh
./tests/update_test.sh
./tests/compose_render_test.sh
./tests/data_safety_test.sh
```

Expected: every script prints its `passed` line.

- [ ] **Step 9: Commit**

```bash
git add jellyfin tests/compose_render_test.sh tests/data_safety_test.sh
git commit -m "feat: add Jellyfin stack"
```

---

### Task 9: Add CI

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the CI workflow**

Create `.github/workflows/ci.yml` with exactly:

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
        run: shellcheck stack tests/*.sh

      - name: Stack tests
        run: |
          ./tests/init_test.sh
          ./tests/check_test.sh
          ./tests/lifecycle_test.sh
          ./tests/update_test.sh

      - name: Compose render tests
        run: ./tests/compose_render_test.sh

      - name: Data safety tests
        run: ./tests/data_safety_test.sh
```

- [ ] **Step 2: Run shellcheck locally**

```bash
shellcheck stack tests/*.sh
```

Expected: no output, exit code 0. If `shellcheck` is not installed locally, install it or rely on CI; do not ignore warnings.

- [ ] **Step 3: Run the full test suite**

```bash
./tests/init_test.sh
./tests/check_test.sh
./tests/lifecycle_test.sh
./tests/update_test.sh
./tests/compose_render_test.sh
./tests/data_safety_test.sh
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: run stack and compose tests"
```

---

### Task 10: Document install, operations, and adoption

**Files:**
- Move: `namecheap_dns.py` -> `tools/dns/namecheap_dns.py`
- Move: `README.md` -> `tools/dns/README.md`
- Create: `README.md`
- Create: `docs/install.md`
- Create: `docs/operations.md`
- Create: `docs/adopt-existing-server.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Move the DNS tooling**

```bash
mkdir -p tools/dns
git mv namecheap_dns.py tools/dns/namecheap_dns.py
git mv README.md tools/dns/README.md
```

Add this note near the top of `tools/dns/README.md`:

```markdown
Run these commands from this directory, or run `tools/dns/namecheap_dns.py`
from the repo root. Environment variables are still read from the shell; source
`../../.namecheap.env` from the repo root or export them directly.
```

- [ ] **Step 2: Write the root README**

Create `README.md` with exactly:

````markdown
# homelab-stack

Repo-owned Docker Compose stack with Traefik ingress, per-instance env files,
and a small `stack` CLI. Each service is a directory containing its compose
file and local env files.

## Requirements

- Linux host with Docker Engine and Compose v2
- git and bash
- Ports 80 and 443 free
- DNS wildcard `*.<base-domain>` pointing at the host

## Quick start

```bash
git clone <repo> stack
cd stack
./stack init
$EDITOR .env
$EDITOR jellyfin/.env
./stack init
./stack check
./stack up
```

`./stack init` creates the root `.env` and the per-service env files on the
first run. Edit them, run `init` again to create data directories and
`acme.json`, then `check` and `up`.

Do not fork or use this as a template if you want upstream updates. Clone the
repo directly; `.env`, `*/.env`, and `*/.secrets` are ignored, so pulls never
conflict. Put local values in those files. If you edit tracked files,
`stack update` will refuse to run.

## Layout

```text
.
├── .env                 # instance values
├── stack
├── traefik/compose.yaml
├── jellyfin/
│   ├── compose.yaml
│   ├── .env
│   └── .secrets
└── ...
```

Persistent data lives under `${DATA_ROOT}/<service>`, never inside the repo.

## Commands

```text
./stack init                 Create env files and required directories
./stack check                Validate env files and compose configuration
./stack up                   Start Traefik and enabled services
./stack down                 Stop services and Traefik (keeps data)
./stack status               Show container status
./stack logs <service>       Follow logs
./stack restart <service>    Restart a service
./stack update [--version v] Check out a release tag and redeploy
./stack doctor               Print redacted diagnostics
```

## Services

| Service | Domain | Upstream |
| --- | --- | --- |
| Jellyfin | `flix.<base>` | `127.0.0.1:8096` |
| Immich | `photos.<base>` | `127.0.0.1:2283` |
| Tandoor | `recipes.<base>` | `127.0.0.1:8979` |
| Authentik | `id.<base>` | `127.0.0.1:9000` |
| Papra | `docs.<base>` | `127.0.0.1:1221` |
| Checkmate | `status.<base>` / `info.status.<base>` | `127.0.0.1:52345` |

Only Jellyfin is converted in this phase. The others are follow-on work.

## Updates

```bash
git fetch --tags
./stack update
```

Rollback is `git checkout <previous-tag> && ./stack up`. Back up
`${DATA_ROOT}`, the root `.env`, and all `*/.env` / `*/.secrets` files before
updating. Database migrations may not be reversible.

## Data safety

Every persistent path is a bind mount under `${DATA_ROOT}/<service>`. No service
uses a named or anonymous data volume. `stack down` rejects `-v` and
`--volumes`, and `stack check` fails if a rendered mount has `type: volume`.
`docker compose down -v` and volume pruning therefore cannot remove application
data. Back up `${DATA_ROOT}` separately; bind mounts do not protect against
`rm -rf`.

## Notes

- `tools/dns/` contains optional Namecheap DNS tooling for the reference
  deployment. It is not required to use this stack.
- `docs/install.md`, `docs/operations.md`, and `docs/adopt-existing-server.md`
  cover the details.
- Never commit `.env`, `*/.env`, `*/.secrets`, `.namecheap.env`, or
  `*/compose.override.yaml`.
````

- [ ] **Step 3: Write `docs/install.md`**

Create `docs/install.md` with exactly:

````markdown
# Install

## Prerequisites

- Docker Engine with Compose v2
- `git`, `bash`, `openssl`, `curl`
- Public IP with inbound TCP 80 and 443
- A wildcard DNS record `*.<base-domain>` pointing at the host

## Install

```bash
git clone <repo> stack
cd stack
./stack init
```

Edit the root `.env`:

```dotenv
BASE_DOMAIN=example.com
ACME_EMAIL=you@example.com
DATA_ROOT=/srv/stack
TZ=Europe/London
PUID=1000
PGID=1000
ENABLED_SERVICES=jellyfin
```

Edit service values as needed:

```bash
$EDITOR jellyfin/.env
```

Run:

```bash
./stack init
./stack check
./stack up
```

## Verify

```bash
./stack status
curl -sI "https://flix.${BASE_DOMAIN}/" | head
docker logs traefik --tail=50
```

The first request may take a few seconds while Traefik obtains the certificate.

## Hardware transcoding

The base Jellyfin compose does not request `/dev/dri`. On hosts that have it:

```bash
cp jellyfin/compose.override.yaml.example jellyfin/compose.override.yaml
./stack up
```

Adjust the render device path if it is not `/dev/dri/renderD128`.
````

- [ ] **Step 4: Write `docs/operations.md`**

Create `docs/operations.md` with exactly:

````markdown
# Operations

## Daily commands

```bash
./stack status
./stack logs jellyfin
./stack restart jellyfin
./stack down
./stack up
```

`down` never removes data, and `stack down -v` is rejected.

## Data safety

All persistent data is bind-mounted under `${DATA_ROOT}`. There are no named or
anonymous data volumes. `docker compose down -v`, `docker volume prune`, and
`docker system prune --volumes` cannot remove bind-mounted data. Run
`./stack check` to verify that no rendered mount has `type: volume`.

Bind mounts do not protect against `rm -rf ${DATA_ROOT}` or disk failure. Keep
independent backups.

## Updates

```bash
git fetch --tags
./stack update
```

Pin the version with:

```bash
./stack update --version v0.2.0
```

Rollback:

```bash
git checkout <previous-tag>
./stack up
```

Back up `${DATA_ROOT}`, the root `.env`, and all `*/.env` / `*/.secrets` files
first. Database migrations may not be reversible.

## Backups

Back up these separately:

- `${DATA_ROOT}`: application data and databases
- root `.env`
- every `*/.env`
- every `*/.secrets`
- `${DATA_ROOT}/traefik/acme.json`

The repo itself contains no persistent data.

## TLS

Traefik stores ACME state in `${DATA_ROOT}/traefik/acme.json` (mode 0600).
Certificates are requested per host by HTTP-01, so inbound port 80 must be
reachable and DNS must already point at the host.

## Troubleshooting

```bash
./stack check
./stack doctor
docker logs traefik --tail=100
docker compose ls
```

If a service returns 502, confirm its loopback port is listening:

```bash
ss -ltnp | grep 8096
```

## Security

Traefik and Checkmate mount the Docker socket read-only, but that is still
root-equivalent on the host. Do not run untrusted containers. Do not expose the
Traefik dashboard.
````

- [ ] **Step 5: Write `docs/adopt-existing-server.md`**

Create `docs/adopt-existing-server.md` with exactly:

````markdown
# Adopt an existing server

This runbook is for the reference server, which currently runs nginx and
per-service compose files under `~/<service>/`. Do not run it until the
follow-on plans have added every service to Traefik.

## 1. Back up

```bash
backup="$HOME/backups/stack-$(date +%F-%H%M)"
mkdir -p "$backup"
for service in jellyfin immich tandoor authentik papra checkmate; do
  file="$HOME/$service/docker-compose.yml"
  [[ -f "$file" ]] || file="$HOME/$service/docker-compose.yaml"
  docker compose -f "$file" config \
    > "$backup/$service.compose.resolved.yml" 2>/dev/null || true
  cp "$file" "$backup/" 2>/dev/null || true
  cp "$HOME/$service/.env" "$backup/$service.env" 2>/dev/null || true
done
cp -a "$HOME/nginx/examples/user_conf.d" "$backup/nginx-user_conf.d"
sudo tar -C "$HOME/nginx/examples" -czf "$backup/letsencrypt.tgz" letsencrypt
docker volume ls > "$backup/docker-volumes.txt"
```

Never commit the backup directory.

## 2. Prepare the instance

```bash
git clone <repo> "$HOME/stack"
cd "$HOME/stack"
cp .env.example .env
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

At the time of the eventual cutover, every listed service must already have a
Traefik route. Until then, leave nginx running and keep this list to the
services that have been migrated.

Copy each existing `~/<service>/.env` into `<service>/.env` and `<service>/.secrets`,
keeping the application's natural variable names and moving secrets into
`.secrets`. Do not commit either file.

Run:

```bash
./stack init
./stack check
```

## 3. Hardware transcoding

```bash
cp jellyfin/compose.override.yaml.example jellyfin/compose.override.yaml
```

Confirm the render device path exists.

## 4. Migrate old named volumes

If the old stack used named volumes, copy their contents into the bind paths
before starting the new compose files:

```bash
sudo mkdir -p /home/layz/authentik/database
docker run --rm \
  -v authentik_database:/from:ro \
  -v /home/layz/authentik/database:/to \
  alpine:3.20 sh -c 'cp -a /from/. /to/'
```

Repeat for `checkmate_mongo-data`, `tandoor_staticfiles`, and
`immich_model-cache`, using the corresponding `${DATA_ROOT}/<service>/...`
destination. Do not remove the old volumes until the new stack has been verified.

## 5. Verify data paths

The new Jellyfin compose uses:

- `${DATA_ROOT}/jellyfin/config` -> `/config`
- `${DATA_ROOT}/jellyfin/cache` -> `/cache`
- `${JELLYFIN_MEDIA_PATH}` -> `/media`

These must match the old container's mounts. Check with:

```bash
docker inspect jellyfin --format '{{json .Mounts}}' | python3 -m json.tool
```

## 6. Cut over ingress

Do this only after every service has a Traefik route. Stop nginx without
removing data:

```bash
docker compose -f "$HOME/nginx/examples/docker-compose.yml" down
./stack up
```

## 7. Verify

```bash
for host in flix photos recipes id docs status info.status; do
  printf '%s: ' "$host"
  curl -s -o /dev/null -w '%{http_code}\n' "https://$host.priyav.dev/"
done
docker logs traefik --tail=100
```

Verify an Authentik login and one Jellyfin playback.

## 8. Rollback

```bash
./stack down
docker compose -f "$HOME/nginx/examples/docker-compose.yml" up -d
docker compose -f "$HOME/jellyfin/docker-compose.yml" up -d
```

Keep the old compose files and nginx certificates until the new stack has been
stable for an agreed period.
````

- [ ] **Step 6: Update `AGENTS.md`**

Replace its contents with:

````markdown
# homelab-stack

This repo is the source of truth for the Docker Compose stack. `stack` is the
operator interface; Traefik provides ingress and certificates from container
labels.

## Commands

```bash
./stack init
./stack check
./stack up
./stack status
./stack logs <service>
./stack update
./stack doctor
```

## Layout

- `<service>/compose.yaml`: service stack, explicit `name:`
- `<service>/.env`: service values (gitignored)
- `<service>/.secrets`: service secrets, mode 0600 (gitignored)
- `<service>/compose.override.yaml`: host-specific overrides (gitignored)
- root `.env`: instance values (gitignored)
- `tools/dns/`: optional Namecheap tooling

Persistent data lives under `${DATA_ROOT}/<service>`, outside the repo. All
persistent paths are bind mounts; do not introduce named or anonymous volumes.
`stack check` rejects `type: volume`, and `stack down -v` is rejected.

## Current phase

Jellyfin is the first converted service. Other services and the nginx cutover
are follow-on work. Do not stop nginx until every public host has a Traefik
route.

## Server notes

- SSH: `ssh homeserver`
- Current data root: `/home/layz`
- Current media path: `/mnt/seagate`
- Traefik uses `/var/run/docker.sock:ro`; this is root-equivalent.
````

- [ ] **Step 7: Run all tests and commit**

```bash
./tests/init_test.sh
./tests/check_test.sh
./tests/lifecycle_test.sh
./tests/update_test.sh
./tests/compose_render_test.sh
git add README.md AGENTS.md docs tools
git commit -m "docs: add install and operations runbooks"
```

---

### Task 11: Tag the foundation release

**Files:** none

- [ ] **Step 1: Run the full validation suite**

```bash
shellcheck stack tests/*.sh
./tests/init_test.sh
./tests/check_test.sh
./tests/lifecycle_test.sh
./tests/update_test.sh
./tests/compose_render_test.sh
./tests/data_safety_test.sh
```

Expected: shellcheck exits 0 and all six scripts print `passed`.

- [ ] **Step 2: Verify no local files are tracked**

```bash
git status --short
git ls-files | grep -E '(^|/)(\.env|\.secrets|\.namecheap\.env|compose\.override\.yaml)$' && exit 1 || true
```

Expected: no `.env`, `.secrets`, `.namecheap.env`, or override file in the
tracked file list.

- [ ] **Step 3: Tag**

```bash
git tag -a v0.1.0 -m "repo deployment foundation"
git tag --list 'v*'
```

Expected: `v0.1.0`.

Do not push until the user asks.

---

## Definition of done

- `git status` is clean.
- `shellcheck stack tests/*.sh` passes.
- All six test scripts pass.
- `traefik/compose.yaml` and `jellyfin/compose.yaml` render with
  `BASE_DOMAIN=example.test`.
- No rendered mount has `"type": "volume"`.
- No tracked secrets or instance domains.
- `v0.1.0` exists.
- Production nginx is still running; no live cutover has happened.

## Follow-on plans

1. **Phase 2:** convert Immich, Tandoor, Authentik, Papra, and Checkmate using
   the same per-service directory pattern. Each service gets a compose file,
   env templates, data directories, labels, and render assertions.
2. **Phase 3:** stop nginx, start Traefik on 80/443, verify every public host,
   and add the optional systemd update timer.

Do not start Phase 2 until this plan's tests pass and the Jellyfin compose has
been reviewed against the running container's mounts.

---

## Self-review

- **Spec coverage:** service directories (Tasks 1-3, 7-8), root and per-service
  env (Tasks 2-4), Traefik labels (Tasks 7-8), `stack` interface (Tasks 3-6),
  external bind-mounted data (Tasks 3, 8, adoption doc), data-safety guardrails
  (Tasks 4-5, 8-9), tests (Tasks 3-9), docs (Task 10), release tag (Task 11).
- **Placeholders:** none; every code step contains complete content.
- **Consistency:** `STACK_ROOT`, `DOCKER_BIN`, `enabled_services`, `compose`,
  `service`, and `cmd_*` names are used consistently across tasks.
- **Deliberate gap:** remaining services and the live cutover are follow-on
  plans because nginx must continue serving their domains until they are
  migrated.
