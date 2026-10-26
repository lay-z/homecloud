#!/usr/bin/env bash
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"

usage() {
  printf 'usage: %s <volume> <absolute-destination>\n' "$0" >&2
  exit 1
}

volume="${1:-}"
dest="${2:-}"
[[ -n "$volume" && -n "$dest" ]] || usage
[[ "$dest" == /* ]] || {
  printf 'destination must be absolute: %s\n' "$dest" >&2
  exit 1
}

mkdir -p "$dest"
if [[ -n "$(ls -A "$dest")" ]]; then
  printf 'destination is not empty: %s\n' "$dest" >&2
  exit 1
fi

"$DOCKER_BIN" volume inspect "$volume" >/dev/null
"$DOCKER_BIN" run --rm \
  -v "$volume:/from:ro" \
  -v "$dest:/to" \
  alpine:3.20 sh -c 'cp -a /from/. /to/'
