#!/usr/bin/env bash
set -euo pipefail

MIGRATIONS_DIR="${MIGRATIONS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$MIGRATIONS_DIR/lib.sh"

container=checkmate-mongodb-1
[[ -n "${BACKUP_DIR:-}" ]] || die "BACKUP_DIR is not set"

compose_svc config --images | grep -Fq "mongo:$RELEASE" ||
  die "checkmate/compose.yaml must pin mongo:$RELEASE before this migration runs"

info "starting $container on MongoDB $RELEASE"
compose_svc up -d mongodb
wait_healthy "$container" 90 2

archive="$BACKUP_DIR/checkmate-mongo.gz"
# Stream the dump straight to BACKUP_ROOT. Writing it inside the container
# first would put a second copy on the Docker root filesystem, which is the
# small disk this migration is trying to avoid filling.
if ! "${DOCKER_BIN:-docker}" exec "$container" mongodump --quiet --archive --gzip > "$archive.partial"; then
  rm -f "$archive.partial"
  die "mongodump failed; the feature compatibility version was not changed"
fi
[[ -s "$archive.partial" ]] || { rm -f "$archive.partial"; die "mongodump produced an empty archive"; }
mv "$archive.partial" "$archive"
( cd "$BACKUP_DIR" && sha256sum checkmate-mongo.gz >> SHA256SUMS )
info "backup: $archive"

info "setting feature compatibility version to $RELEASE"
# MongoDB 6.0+ requires confirm: true for a major FCV change.
"${DOCKER_BIN:-docker}" exec "$container" mongosh --quiet \
  --eval "db.adminCommand({setFeatureCompatibilityVersion: '$RELEASE', confirm: true})" >/dev/null

current="$("${DOCKER_BIN:-docker}" exec "$container" mongosh --quiet \
  --eval 'db.adminCommand({getParameter:1,featureCompatibilityVersion:1}).featureCompatibilityVersion.version' |
  grep -Eo '[0-9]+\.[0-9]+' | head -n1 || true)"
[[ -n "$current" ]] || die "could not read the feature compatibility version after the change"
[[ "$current" == "$RELEASE" ]] || die "FCV is $current, expected $RELEASE"

info "FCV is $RELEASE"
if [[ "$RELEASE" == 9.0 ]]; then
  warn "FCV 9.0 cannot be downgraded; keep the mongodump archive until Checkmate is verified"
fi
