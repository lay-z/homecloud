#!/usr/bin/env bash
set -euo pipefail

ROOT="${STACK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-$ROOT/migrations}"
MANIFEST="$MIGRATIONS_DIR/manifest.tsv"
DOCKER_BIN="${DOCKER_BIN:-docker}"

die() {
  printf 'migrate: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

warn() {
  printf 'migrate: warning: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: ./stack migrate <command>

Commands:
  list                       List migrations and their status
  plan                       Show pending migrations in execution order
  run <id> [--yes] [--force] Run one migration
  validate                   Check the manifest and scripts
  status                     Summarise recorded migrations

Migration manifests live in migrations/manifest.tsv; scripts live beside it.
EOF
}

load_env() {
  [[ -f "$ROOT/.env" ]] || die "missing .env (run ./stack init)"
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/.env"
  set +a
}

enabled_services() {
  local raw="${ENABLED_SERVICES:-}"
  local -a services
  local svc

  raw="${raw// /}"
  IFS=',' read -ra services <<< "$raw"
  for svc in "${services[@]}"; do
    [[ -n "$svc" ]] || continue
    printf '%s\n' "$svc"
  done
}

service_enabled() {
  local wanted="$1" svc
  while IFS= read -r svc; do
    [[ "$svc" == "$wanted" ]] && return 0
  done <<< "$(enabled_services)"
  return 1
}

compose() {
  local service="$1"
  shift
  local dir="$ROOT/$service"
  local args=(-f "$dir/compose.yaml")
  local env_args=(--env-file "$ROOT/.env")

  [[ -d "$dir" ]] || die "unknown service: $service"
  [[ -f "$dir/compose.yaml" ]] || die "missing $service/compose.yaml"

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

manifest_rows() {
  [[ -f "$MANIFEST" ]] || die "missing ${MANIFEST#"$ROOT"/}"
  awk -F'\t' 'BEGIN { OFS="\t" } /^[[:space:]]*#/ { next } /^[[:space:]]*$/ { next } { print }' "$MANIFEST"
}

find_row() {
  local id="$1" row
  while IFS= read -r row; do
    [[ "${row%%$'\t'*}" == "$id" ]] || continue
    printf '%s\n' "$row"
    return 0
  done <<< "$(manifest_rows)"
  return 1
}

split_row() {
  local row="$1"
  # shellcheck disable=SC2034  # the field names mirror the manifest columns
  IFS=$'\t' read -r MIGRATION_ID SERVICE RELEASE KIND NEEDS_STOP BACKUP MIN_FREE SCRIPT DESCRIPTION <<< "$row"
}

journal_path() {
  printf '%s/.migrations/%s' "${DATA_ROOT:-}" "$1"
}

journal_field() {
  local file="$1" key="$2"
  grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

migration_status() {
  local id="$1" file
  [[ -n "${DATA_ROOT:-}" ]] || { printf 'unknown'; return 0; }
  file="$(journal_path "$id")"
  if [[ -f "$file" ]]; then
    printf 'done'
  else
    printf 'pending'
  fi
}

free_mb() {
  df -Pm "$1" | awk 'NR==2 { print $4 }'
}

require_free_mb() {
  local path="$1" required="$2" available
  [[ -d "$path" ]] || die "missing directory: $path"
  available="$(free_mb "$path")"
  [[ -n "$available" ]] || die "could not read free space for $path"
  (( available >= required )) ||
    die "only ${available}MB free on $path; ${required}MB required"
}

validate_manifest() {
  local rows row id script kind needs_stop backup min_free seen=""
  local -a fields
  local count=0

  rows="$(manifest_rows)"
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS=$'\t' read -ra fields <<< "$row"
    (( ${#fields[@]} == 9 )) ||
      die "manifest row has ${#fields[@]} fields, expected 9: $row"

    id="${fields[0]}"
    kind="${fields[3]}"
    needs_stop="${fields[4]}"
    backup="${fields[5]}"
    min_free="${fields[6]}"
    script="${fields[7]}"

    [[ "$id" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || die "invalid migration id: $id"
    grep -qxF "$id" <<< "$seen" && die "duplicate migration id: $id"
    seen+="$id"$'\n'
    case "$kind" in
      preflight|window|post|data) ;;
      *) die "$id: invalid kind: $kind" ;;
    esac
    case "$needs_stop" in yes|no) ;; *) die "$id: needs_stop must be yes or no" ;; esac
    case "$backup" in yes|no) ;; *) die "$id: backup must be yes or no" ;; esac
    [[ "$min_free" =~ ^[0-9]+$ ]] || die "$id: min_free_mb must be a number"
    [[ -f "$MIGRATIONS_DIR/$script" ]] || die "$id: missing script $script"
    [[ -x "$MIGRATIONS_DIR/$script" ]] || die "$id: script is not executable: $script"
    count=$((count + 1))
  done <<< "$rows"

  (( count > 0 )) || die "manifest is empty"
  info "manifest ok: $count migrations"
}

cmd_list() {
  local row status

  load_env
  printf '%-32s %-11s %-11s %-10s %-5s %s\n' ID SERVICE RELEASE KIND STOP STATUS
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    split_row "$row"
    if service_enabled "$SERVICE"; then
      status="$(migration_status "$MIGRATION_ID")"
    else
      status="disabled"
    fi
    printf '%-32s %-11s %-11s %-10s %-5s %s\n' \
      "$MIGRATION_ID" "$SERVICE" "$RELEASE" "$KIND" "$NEEDS_STOP" "$status"
  done <<< "$(manifest_rows)"
}

cmd_plan() {
  local row current="" pending=0

  load_env
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    split_row "$row"
    [[ "$(migration_status "$MIGRATION_ID")" == "pending" ]] || continue
    service_enabled "$SERVICE" || continue

    if [[ "$SERVICE" != "$current" ]]; then
      [[ -n "$current" ]] && printf '\n'
      printf '%s\n' "$SERVICE"
      current="$SERVICE"
    fi
    printf '  [%s] %-32s %-11s %s\n' "$KIND" "$MIGRATION_ID" "$RELEASE" "$DESCRIPTION"
    pending=$((pending + 1))
  done <<< "$(manifest_rows)"

  if (( pending == 0 )); then
    info "no pending migrations for enabled services"
  else
    printf '\n%d pending migration(s). Image pins land by pull request and release tag;\n' "$pending"
    printf 'run the listed migrations inside the matching maintenance window.\n'
  fi
}

cmd_status() {
  local row id file count=0

  load_env
  [[ -n "${DATA_ROOT:-}" ]] || die "DATA_ROOT is not set"
  if [[ ! -d "$DATA_ROOT/.migrations" ]]; then
    info "no migrations recorded under $DATA_ROOT/.migrations"
    return 0
  fi

  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    split_row "$row"
    file="$(journal_path "$MIGRATION_ID")"
    [[ -f "$file" ]] || continue
    info "$MIGRATION_ID"
    info "  completed: $(journal_field "$file" completed_at)"
    info "  release:   $(journal_field "$file" release)"
    info "  stack:     $(journal_field "$file" stack_version)"
    count=$((count + 1))
  done <<< "$(manifest_rows)"

  (( count > 0 )) || info "no migrations recorded under $DATA_ROOT/.migrations"
}

cmd_run() {
  local id="" assume_yes=0 force=0 row script_path stamp log backup_dir
  local required script_hash recorded_hash

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) assume_yes=1; shift ;;
      --force) force=1; shift ;;
      -*) die "unknown option: $1" ;;
      *)
        [[ -z "$id" ]] || die "only one migration id may be given"
        id="$1"
        shift
        ;;
    esac
  done
  [[ -n "$id" ]] || die "usage: ./stack migrate run <id> [--yes] [--force]"

  load_env
  [[ -n "${DATA_ROOT:-}" ]] || die "DATA_ROOT is not set"
  row="$(find_row "$id")" || die "unknown migration: $id"
  split_row "$row"

  service_enabled "$SERVICE" || die "$SERVICE is not enabled in ENABLED_SERVICES"
  [[ -d "$ROOT/$SERVICE" ]] || die "unknown service: $SERVICE"

  script_path="$MIGRATIONS_DIR/$SCRIPT"
  [[ -f "$script_path" ]] || die "missing migration script: $SCRIPT"
  [[ -x "$script_path" ]] || die "migration script is not executable: $SCRIPT"

  script_hash="$(sha256sum "$script_path" | cut -d' ' -f1)"
  mkdir -p "$DATA_ROOT/.migrations/logs"
  if [[ -f "$(journal_path "$id")" ]]; then
    if (( force )); then
      info "$id already applied; rerunning because of --force"
    else
      recorded_hash="$(journal_field "$(journal_path "$id")" script_sha256)"
      if [[ -n "$recorded_hash" && "$recorded_hash" != "$script_hash" ]]; then
        warn "$id was applied with a different script; re-run with --force to apply the change"
      fi
      info "$id already applied on $(journal_field "$(journal_path "$id")" completed_at)"
      return 0
    fi
  fi

  required="${MIGRATE_MIN_FREE_MB:-$MIN_FREE}"
  BACKUP_ROOT="${BACKUP_ROOT:-$DATA_ROOT/backups}"
  mkdir -p "$BACKUP_ROOT"
  require_free_mb "$DATA_ROOT" "$required"
  require_free_mb "$BACKUP_ROOT" "$required"

  "$DOCKER_BIN" info >/dev/null 2>&1 || die "cannot reach the Docker daemon"

  if (( ! assume_yes )); then
    [[ -t 0 ]] || die "refusing to run $id without --yes on a non-interactive stdin"
    printf 'Type %s to run: ' "$id"
    read -r answer
    [[ "$answer" == "$id" ]] || die "aborted"
  fi

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  log="$DATA_ROOT/.migrations/logs/${id}-${stamp}.log"
  backup_dir="$BACKUP_ROOT/${stamp}-${id}"
  mkdir -p "$backup_dir"

  info "running $id ($SERVICE $RELEASE)"
  info "log: $log"
  info "backup: $backup_dir"

  if [[ "$NEEDS_STOP" == "yes" ]]; then
    info "stopping $SERVICE"
    compose "$SERVICE" stop
  fi

  set +e
  (
    set -euo pipefail
    export STACK_ROOT="$ROOT"
    export MIGRATIONS_DIR MIGRATION_ID="$id" SERVICE RELEASE KIND
    export BACKUP_DIR="$backup_dir" LOG_FILE="$log"
    export DOCKER_BIN
    if [[ -f "$MIGRATIONS_DIR/lib.sh" ]]; then
      # shellcheck disable=SC1091
      . "$MIGRATIONS_DIR/lib.sh"
    fi
    cd "$ROOT"
    "$script_path"
  ) 2>&1 | tee -a "$log"
  rc=${PIPESTATUS[0]}
  set -e

  if [[ "$NEEDS_STOP" == "yes" ]]; then
    info "starting $SERVICE"
    if ! compose "$SERVICE" up -d --remove-orphans; then
      warn "failed to restart $SERVICE after migration $id"
      (( rc == 0 )) && rc=1
    fi
  fi

  if (( rc != 0 )); then
    printf 'migrate: %s failed (exit %s); not recorded\n' "$id" "$rc" >&2
    exit "$rc"
  fi

  {
    printf 'completed_at=%s\n' "$(date -u +%FT%TZ)"
    printf 'service=%s\n' "$SERVICE"
    printf 'release=%s\n' "$RELEASE"
    printf 'script=%s\n' "$SCRIPT"
    printf 'script_sha256=%s\n' "$script_hash"
    printf 'stack_version=%s\n' "$(git -C "$ROOT" describe --tags --always 2>/dev/null || printf 'unknown')"
  } > "$(journal_path "$id")"

  info "$id recorded"
}

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    list) cmd_list "$@" ;;
    plan) cmd_plan "$@" ;;
    run) cmd_run "$@" ;;
    status) cmd_status "$@" ;;
    validate) validate_manifest "$@" ;;
    help|-h|--help) usage ;;
    *) die "unknown command: $cmd (try ./stack migrate help)" ;;
  esac
}

main "$@"
