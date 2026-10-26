#!/usr/bin/env bash
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"

usage() {
  printf 'usage: %s <volume> <absolute-destination>\n' "$0" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage
volume="$1"
dest="$2"
[[ -n "$volume" && -n "$dest" ]] || usage
[[ "$dest" == /* ]] || {
  printf 'destination must be absolute: %s\n' "$dest" >&2
  exit 1
}

"$DOCKER_BIN" volume inspect "$volume" >/dev/null
if [[ -n "$("$DOCKER_BIN" ps -q --filter "volume=$volume")" ]]; then
  printf 'volume is in use by a running container: %s\n' "$volume" >&2
  exit 1
fi

mkdir -p "$dest"
if ! entries="$(ls -A -- "$dest")"; then
  printf 'cannot inspect destination: %s\n' "$dest" >&2
  exit 1
fi
if [[ -n "$entries" ]]; then
  printf 'destination is not empty: %s\n' "$dest" >&2
  exit 1
fi

"$DOCKER_BIN" run --rm \
  -v "$volume:/from:ro" \
  -v "$dest:/to" \
  alpine:3.20 sh -c 'cp -a /from/. /to/'
