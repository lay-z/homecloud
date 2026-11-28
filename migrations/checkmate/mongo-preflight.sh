#!/usr/bin/env bash
set -euo pipefail

MIGRATIONS_DIR="${MIGRATIONS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$MIGRATIONS_DIR/lib.sh"

container=checkmate-mongodb-1
status="$(container_status "$container")"
[[ "$status" == "running" ]] || die "$container is $status; start the stack first"

mongo_version="$("${DOCKER_BIN:-docker}" exec "$container" mongosh --quiet --eval 'db.version()' |
  grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
fcv="$("${DOCKER_BIN:-docker}" exec "$container" mongosh --quiet \
  --eval 'db.adminCommand({getParameter:1,featureCompatibilityVersion:1}).featureCompatibilityVersion.version' |
  grep -Eo '[0-9]+\.[0-9]+' | head -n1 || true)"

[[ -n "$mongo_version" ]] || die "could not read the MongoDB version"
[[ -n "$fcv" ]] || die "could not read the MongoDB feature compatibility version"

info "mongodb $mongo_version, FCV $fcv -> FCV $RELEASE"

if [[ "$fcv" == "$RELEASE" ]]; then
  info "FCV is already $RELEASE"
  exit 0
fi

case "$RELEASE" in
  8.3)
    expected_fcv=8.0
    expected_major=8.0
    ;;
  9.0)
    expected_fcv=8.3
    expected_major=8.3
    ;;
  *) die "no known MongoDB upgrade sequence for FCV $RELEASE" ;;
esac

[[ "$fcv" == "$expected_fcv" ]] ||
  die "MongoDB upgrades are sequential: FCV must be $expected_fcv before $RELEASE (currently $fcv)"

# Preflight before deploying the new binaries. The runner's following data step
# asserts the compose pin, starts those binaries, takes the dump, then raises FCV.
binary_minor="${mongo_version%.*}"
if [[ "$binary_minor" != "$expected_major" ]]; then
  die "run this preflight while MongoDB $expected_major.x is still serving, before deploying $RELEASE (running $mongo_version)"
fi

"${DOCKER_BIN:-docker}" exec "$container" sh -lc 'command -v mongodump >/dev/null' ||
  die "mongodump is not available in $container"

mongo_data="$DATA_ROOT/checkmate/mongo-data"
if [[ -d "$mongo_data" ]]; then
  info "mongo data: $(du -sh "$mongo_data" 2>/dev/null | cut -f1)"
else
  warn "$mongo_data not found; skipping the size report"
fi

info "preflight passed"
