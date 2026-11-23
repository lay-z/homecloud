#!/usr/bin/env bash
set -euo pipefail

db_user="$(service_env PG_USER authentik)"
db_name="$(service_env PG_DB authentik)"

"${DOCKER_BIN:-docker}" exec authentik-postgresql-1 \
  psql -U "$db_user" -d "$db_name" -v ON_ERROR_STOP=1 -c 'ANALYZE;'

info "refreshed PostgreSQL planner statistics for $db_name"
