#!/usr/bin/env bash
set -euo pipefail

MIGRATIONS_DIR="${MIGRATIONS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$MIGRATIONS_DIR/lib.sh"

wait_http "http://127.0.0.1:9000/-/health/live/" 45 2
wait_http "http://127.0.0.1:9000/-/health/ready/" 45 2

current="$(running_image_tag authentik-server-1 || true)"
[[ "$current" == "$RELEASE" ]] ||
  die "authentik-server-1 is running ${current:-unknown}, expected $RELEASE"

worker_status="$(container_status authentik-worker-1)"
[[ "$worker_status" == "running" ]] || die "authentik-worker-1 is $worker_status"

# Capture the log first: with `set -o pipefail`, a `grep -q` that exits early
# can make `docker logs` die of SIGPIPE and mask the match.
logs="$("${DOCKER_BIN:-docker}" logs authentik-server-1 --since 2h 2>&1 || true)"
if grep -qi 'migration inconsistency' <<< "$logs"; then
  die "authentik reported a migration inconsistency; restore the pre-upgrade backup and repeat the ladder in order"
fi

info "authentik $RELEASE is healthy and reported no migration inconsistency"
