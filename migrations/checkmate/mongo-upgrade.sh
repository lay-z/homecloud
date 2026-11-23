#!/usr/bin/env bash
set -euo pipefail

container=checkmate-mongodb-1
[[ -n "${BACKUP_DIR:-}" ]] || die "BACKUP_DIR is not set"

compose_svc config --images | grep -Fq "mongo:$RELEASE" ||
  die "checkmate/compose.yaml must pin mongo:$RELEASE before this migration runs"

info "starting $container on MongoDB $RELEASE"
compose_svc up -d mongodb
wait_healthy "$container" 90 2

archive="$BACKUP_DIR/checkmate-mongo.gz"
"${DOCKER_BIN:-docker}" exec "$container" mongodump --quiet --archive=/tmp/checkmate-mongo.gz --gzip
"${DOCKER_BIN:-docker}" cp "$container:/tmp/checkmate-mongo.gz" "$archive"
"${DOCKER_BIN:-docker}" exec "$container" rm -f /tmp/checkmate-mongo.gz
[[ -s "$archive" ]] || die "mongodump produced an empty archive"
( cd "$BACKUP_DIR" && sha256sum checkmate-mongo.gz >> SHA256SUMS )
info "backup: $archive"

info "setting feature compatibility version to $RELEASE"
"${DOCKER_BIN:-docker}" exec "$container" mongosh --quiet \
  --eval "db.adminCommand({setFeatureCompatibilityVersion: '$RELEASE'})" >/dev/null

current="$("${DOCKER_BIN:-docker}" exec "$container" mongosh --quiet \
  --eval 'db.adminCommand({getParameter:1,featureCompatibilityVersion:1}).featureCompatibilityVersion.version' |
  grep -Eo '[0-9]+\.[0-9]+' | head -n1)"
[[ "$current" == "$RELEASE" ]] || die "FCV is $current, expected $RELEASE"

info "FCV is $RELEASE"
if [[ "$RELEASE" == 9.0 ]]; then
  warn "FCV 9.0 cannot be downgraded; keep the mongodump archive until Checkmate is verified"
fi
