#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

assert_not_file() {
  [[ ! -e "$1" ]] || fail "unexpected file: $1"
}

fixture="$TMP/repo"
mkdir -p "$fixture/authentik"
cat > "$fixture/authentik/compose.yaml" <<'YAML'
services:
  server:
    volumes:
      - ${DATA_ROOT}/authentik/data:/data
  worker:
    volumes:
      - ${DATA_ROOT}/authentik/data:/data
YAML

data_root="$TMP/auth-data"
backup_dir="$TMP/auth-backups/both-present"
mkdir -p "$data_root/authentik/media" "$data_root/authentik/data/media"
printf 'old upload\n' > "$data_root/authentik/media/old.txt"
printf 'new upload\n' > "$data_root/authentik/data/media/new.txt"

if STACK_ROOT="$fixture" SERVICE=authentik DATA_ROOT="$data_root" \
  BACKUP_DIR="$backup_dir" "$ROOT/migrations/authentik/storage-layout.sh" \
  >"$TMP/storage-both.out" 2>&1; then
  fail "storage migration silently accepted two populated media directories"
fi
assert_contains "$TMP/storage-both.out" "contain files"
assert_file "$data_root/authentik/media/old.txt"
assert_file "$data_root/authentik/data/media/new.txt"
assert_file "$backup_dir/authentik-media.tar.gz"
[[ "$(tar -xzOf "$backup_dir/authentik-media.tar.gz" media/old.txt)" == "old upload" ]] ||
  fail "storage collision backup omitted the existing media"

data_root="$TMP/auth-data-empty-destination"
backup_dir="$TMP/auth-backups/empty-destination"
mkdir -p "$data_root/authentik/media" "$data_root/authentik/data/media"
printf 'old upload\n' > "$data_root/authentik/media/old.txt"

STACK_ROOT="$fixture" SERVICE=authentik DATA_ROOT="$data_root" \
  BACKUP_DIR="$backup_dir" "$ROOT/migrations/authentik/storage-layout.sh" \
  >"$TMP/storage-empty.out"
assert_file "$data_root/authentik/data/media/old.txt"
assert_not_file "$data_root/authentik/media"
assert_file "$backup_dir/authentik-media.tar.gz"

# The server and worker mounts are both required for the new storage layout.
cat > "$fixture/authentik/compose.yaml" <<'YAML'
services:
  server:
    volumes:
      - ${DATA_ROOT}/authentik/data:/data
  worker:
    volumes:
      - ${DATA_ROOT}/authentik/media:/media
YAML
if STACK_ROOT="$fixture" SERVICE=authentik DATA_ROOT="$TMP/auth-data-missing-worker" \
  BACKUP_DIR="$TMP/auth-backups/missing-worker" \
  "$ROOT/migrations/authentik/storage-layout.sh" >"$TMP/storage-mount.err" 2>&1; then
  fail "storage migration accepted a worker that still mounts /media"
fi
assert_contains "$TMP/storage-mount.err" "worker must mount authentik/data:/data"

# The host-mode Traefik route can arrive from loopback or the Authentik
# container network gateway. Require CIDRs that actually contain both IPs.
# shellcheck disable=SC1091
source "$ROOT/migrations/lib.sh"
if ! cidrs_include_ips "127.0.0.0/8,172.22.0.0/16" 127.0.0.1 172.22.0.1; then
  fail "CIDR validation rejected ranges covering the proxy source addresses"
fi
if cidrs_include_ips "10.0.0.0/8,172.16.0.0/16" 127.0.0.1 172.22.0.1; then
  fail "CIDR validation accepted private ranges that do not cover the proxy sources"
fi
if cidrs_include_ips "127.not-a-cidr" 127.0.0.1 2>/dev/null; then
  fail "CIDR validation accepted malformed input"
fi

mkdir -p "$fixture/bin"
cat > "$fixture/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$*" in
  "inspect authentik-server-1 --format {{.Config.Image}}")
    printf '%s\n' 'ghcr.io/goauthentik/server:2025.12.6@sha256:test'
    ;;
  "inspect jellyfin --format {{.Config.Image}}")
    printf '%s\n' 'jellyfin/jellyfin:12.4@sha256:test'
    ;;
  "inspect checkmate-mongodb-1 --format {{.State.Status}}")
    printf 'running\n'
    ;;
  *"--eval db.version()"*)
    printf '8.3.0\n'
    ;;
  *"featureCompatibilityVersion.version"*)
    printf '8.0\n'
    ;;
esac
DOCKER
chmod +x "$fixture/bin/docker"

if STACK_ROOT="$fixture" SERVICE=authentik DATA_ROOT="$data_root" RELEASE=2025.12.6 \
  DOCKER_BIN="$fixture/bin/docker" "$ROOT/migrations/authentik/preflight.sh" \
  >"$TMP/authentik-too-late.err" 2>&1; then
  fail "Authentik preflight accepted a target image that was already deployed"
fi
assert_contains "$TMP/authentik-too-late.err" "before deploying"

if STACK_ROOT="$fixture" SERVICE=jellyfin DATA_ROOT="$data_root" RELEASE=12.4 \
  DOCKER_BIN="$fixture/bin/docker" "$ROOT/migrations/jellyfin/12-preflight.sh" \
  >"$TMP/jellyfin-too-late.err" 2>&1; then
  fail "Jellyfin preflight accepted a target image that was already deployed"
fi
assert_contains "$TMP/jellyfin-too-late.err" "before deploying 12"

if STACK_ROOT="$fixture" SERVICE=checkmate DATA_ROOT="$data_root" RELEASE=8.3 \
  DOCKER_BIN="$fixture/bin/docker" "$ROOT/migrations/checkmate/mongo-preflight.sh" \
  >"$TMP/mongo-too-late.err" 2>&1; then
  fail "MongoDB preflight accepted target binaries that were already deployed"
fi
assert_contains "$TMP/mongo-too-late.err" "before deploying 8.3"

printf 'migration safety tests passed\n'
