#!/usr/bin/env bash
# Shared helpers for migrations/*.  Sourced by tools/migrate.sh before each
# migration script runs.  Do not execute directly.

die() {
  printf 'migration: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

warn() {
  printf 'migration: warning: %s\n' "$*" >&2
}

service_env() {
  local key="$1" default="${2:-}" value="" file
  for file in "$STACK_ROOT/$SERVICE/.env" "$STACK_ROOT/$SERVICE/.secrets" "$STACK_ROOT/.env"; do
    [[ -f "$file" ]] || continue
    value="$(grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2- || true)"
    [[ -n "$value" ]] && break
  done
  printf '%s' "${value:-$default}"
}

compose_svc() {
  local dir="$STACK_ROOT/$SERVICE"
  local args=(-f "$dir/compose.yaml")
  local env_args=(--env-file "$STACK_ROOT/.env")

  [[ -f "$dir/compose.override.yaml" ]] && args+=(-f "$dir/compose.override.yaml")
  [[ -f "$dir/.env" ]] && env_args+=(--env-file "$dir/.env")
  [[ -f "$dir/.secrets" ]] && env_args+=(--env-file "$dir/.secrets")

  (
    cd "$dir" || die "cannot enter $dir"
    "${DOCKER_BIN:-docker}" compose "${env_args[@]}" "${args[@]}" "$@"
  )
}

running_image_tag() {
  local container="$1" image tag
  image="$("${DOCKER_BIN:-docker}" inspect "$container" --format '{{.Config.Image}}' 2>/dev/null)" ||
    return 1
  [[ -n "$image" ]] || return 1
  tag="${image##*/}"
  tag="${tag#*:}"
  printf '%s' "${tag%%@*}"
}

assert_compose_image() {
  local expected="$1"
  compose_svc config --images | grep -Fq "$expected" ||
    die "$SERVICE must be pinned to $expected before this migration runs"
}

compose_config_has() {
  local needle="$1" file="$STACK_ROOT/$SERVICE/compose.yaml"
  grep -Fq -- "$needle" "$file" ||
    die "$SERVICE/compose.yaml must contain '$needle' before this migration runs"
}

wait_http() {
  local url="$1" tries="${2:-30}" delay="${3:-2}" i
  for ((i = 1; i <= tries; i++)); do
    if curl -fsS -o /dev/null --max-time 5 "$url"; then
      return 0
    fi
    sleep "$delay"
  done
  die "timed out waiting for $url"
}

wait_healthy() {
  local container="$1" tries="${2:-60}" delay="${3:-2}" state i
  for ((i = 1; i <= tries; i++)); do
    state="$("${DOCKER_BIN:-docker}" inspect "$container" \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    [[ "$state" == "healthy" || "$state" == "running" ]] && return 0
    sleep "$delay"
  done
  die "timed out waiting for $container to become healthy"
}

container_status() {
  "${DOCKER_BIN:-docker}" inspect "$1" --format '{{.State.Status}}' 2>/dev/null || printf 'missing'
}

# backup_path <path> <name>
# Archives a host path into $BACKUP_DIR and verifies the archive.
backup_path() {
  local src="$1" name="$2" parent base
  [[ -e "$src" ]] || { warn "nothing to back up at $src"; return 0; }
  [[ -n "${BACKUP_DIR:-}" ]] || die "BACKUP_DIR is not set"
  parent="$(dirname "$src")"
  base="$(basename "$src")"
  mkdir -p "$BACKUP_DIR"
  tar -C "$parent" -czf "$BACKUP_DIR/$name.tar.gz" "$base"
  tar -tzf "$BACKUP_DIR/$name.tar.gz" >/dev/null
  ( cd "$BACKUP_DIR" && sha256sum "$name.tar.gz" >> SHA256SUMS )
  info "backed up $src -> $BACKUP_DIR/$name.tar.gz"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}
