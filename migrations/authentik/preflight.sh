#!/usr/bin/env bash
set -euo pipefail

MIGRATIONS_DIR="${MIGRATIONS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$MIGRATIONS_DIR/lib.sh"

container=authentik-server-1
current="$(running_image_tag "$container" || true)"

if [[ -z "$current" ]]; then
  warn "$container is not running; reading the compose pin instead"
  current="$(compose_svc config --images | grep -F 'goauthentik/server:' | head -n1 || true)"
  current="${current%%@*}"
  current="${current##*:}"
fi

[[ -n "$current" ]] || die "could not determine the authentik version"

info "authentik $current -> $RELEASE"

case "$RELEASE" in
  2025.12.*) previous=2025.10 ;;
  2026.2.*) previous=2025.12 ;;
  2026.5.*) previous=2026.2 ;;
  2026.8.*) previous=2026.5 ;;
  *) die "no known upgrade sequence for $RELEASE" ;;
esac

# This step checks the data state, not the image version: ./stack update
# deploys the new image before the data half runs, so $RELEASE is normally
# already serving when we get here. Re-running the checks against it is
# harmless and keeps the duplicate-name guard alive.
current_minor="${current%.*}"
release_minor="${RELEASE%.*}"

if [[ "$current_minor" == "$release_minor" ]]; then
  info "$current already serves $RELEASE; checking the state the migration needs"
elif [[ "$current_minor" == "$previous" ]]; then
  info "sequential step $previous -> $RELEASE confirmed"
else
  newest="$(printf '%s\n%s\n' "$current_minor" "$release_minor" | sort -V | tail -n1)"
  if [[ "$newest" == "$current_minor" ]]; then
    info "already at $current, which is newer than $RELEASE; nothing to do"
    exit 0
  fi
  die "authentik upgrades are sequential: run the $previous step before $RELEASE (currently $current)"
fi

[[ -n "$(service_env AUTHENTIK_SECRET_KEY)" ]] ||
  die "AUTHENTIK_SECRET_KEY is empty in authentik/.secrets"

status="$(container_status authentik-postgresql-1)"
[[ "$status" == "running" ]] || die "authentik-postgresql-1 is $status; start the stack first"

db_user="$(service_env PG_USER authentik)"
db_name="$(service_env PG_DB authentik)"

duplicates="$("${DOCKER_BIN:-docker}" exec authentik-postgresql-1 \
  psql -U "$db_user" -d "$db_name" -tAc \
  "select name from authentik_core_group group by name having count(*) > 1" | sed '/^[[:space:]]*$/d')"
if [[ -n "$duplicates" ]]; then
  printf 'duplicate group names:\n%s\n' "$duplicates" >&2
  die "2025.12 enforces group-name uniqueness at the database level; rename these groups before upgrading"
fi
info "no duplicate group names"

authentik_root="$DATA_ROOT/authentik"
if [[ -d "$authentik_root/data/media" ]]; then
  info "storage layout already uses data/media"
elif [[ -d "$authentik_root/media" ]]; then
  info "storage layout still uses media/; the storage migration will move it"
else
  warn "no authentik media directory found; treating this as a fresh install"
fi

if [[ "$RELEASE" == 2025.12.* ]]; then
  compose_config_has 'authentik/data:/data'
fi

if [[ "$RELEASE" == 2026.8.* ]]; then
  cidrs="$(service_env AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS)"
  if [[ -n "$cidrs" ]]; then
    info "explicit trusted proxy CIDRs: $cidrs"
    [[ "$cidrs" == *"127."* || "$cidrs" == *"172.16"* || "$cidrs" == *"10."* || "$cidrs" == *"192.168."* ]] ||
      die "AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS does not cover the Traefik source address"
  else
    info "no explicit trusted proxy CIDRs; the defaults cover loopback and RFC1918"
  fi
fi

info "preflight passed"
