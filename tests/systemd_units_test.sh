#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
service="$ROOT/systemd/stack-update.service"
timer="$ROOT/systemd/stack-update.timer"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local needle="$2"
  local message="$3"

  grep -Fq -- "$needle" "$file" || fail "$message"
}

[[ -f "$service" ]] || fail "missing systemd/stack-update.service"
[[ -f "$timer" ]] || fail "missing systemd/stack-update.timer"

assert_contains "$service" 'Type=oneshot' 'stack-update.service is not a oneshot unit'
assert_contains "$service" 'WorkingDirectory=%h/stack' 'stack-update.service working directory missing'
assert_contains "$service" 'ExecStart=/usr/bin/env bash %h/stack/stack update' 'stack-update.service does not run stack update'

assert_contains "$timer" 'OnCalendar=*-*-* 04:00:00' 'update timer schedule missing'
assert_contains "$timer" 'RandomizedDelaySec=3600' 'update timer randomized delay missing'
assert_contains "$timer" 'Persistent=true' 'update timer is not persistent'
assert_contains "$timer" 'Unit=stack-update.service' 'update timer does not target the update service'
assert_contains "$timer" 'WantedBy=timers.target' 'update timer is not installable'

printf 'systemd unit tests passed\n'
