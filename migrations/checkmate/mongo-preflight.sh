#!/usr/bin/env bash
set -euo pipefail

container=checkmate-mongodb-1
status="$(container_status "$container")"
[[ "$status" == "running" ]] || die "$container is $status; start the stack first"

mongo_version="$("${DOCKER_BIN:-docker}" exec "$container" mongosh --quiet --eval 'db.version()' |
  grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
fcv="$("${DOCKER_BIN:-docker}" exec "$container" mongosh --quiet \
  --eval 'db.adminCommand({getParameter:1,featureCompatibilityVersion:1}).featureCompatibilityVersion.version' |
  grep -Eo '[0-9]+\.[0-9]+' | head -n1)"

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

[[ "$mongo_version" == "$expected_major".* ]] ||
  die "MongoDB binaries are $mongo_version; expected $expected_major.x before FCV $RELEASE"
[[ "$fcv" == "$expected_fcv" ]] ||
  die "MongoDB upgrades are sequential: FCV must be $expected_fcv before $RELEASE (currently $fcv)"

assert_compose_image "mongo:$RELEASE"
"${DOCKER_BIN:-docker}" exec "$container" sh -lc 'command -v mongodump >/dev/null' ||
  die "mongodump is not available in $container"

info "mongo data: $(du -sh "$DATA_ROOT/checkmate/mongo-data" | cut -f1)"
info "preflight passed"
