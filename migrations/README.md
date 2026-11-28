# Migrations

Data changes that cannot be expressed as a compose file edit. The operator
entry point is `./stack migrate`; the full upgrade plan is in
[`docs/upgrades.md`](../docs/upgrades.md).

## Files

- `manifest.tsv`: the ordered list of migrations. See the column header.
- `lib.sh`: helpers that each migration script sources.
- `<service>/<step>.sh`: executable migration scripts.

## Script contract

A migration script runs as its own process, with `bash -euo pipefail`, from the
repo root. `lib.sh` is not inherited across that boundary, so every script
sources it itself:

```bash
MIGRATIONS_DIR="${MIGRATIONS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=SCRIPTDIR/../lib.sh
. "$MIGRATIONS_DIR/lib.sh"
```

That also makes a step runnable by hand for a read-only inspection.

The runner exports these variables:

| Variable | Meaning |
| --- | --- |
| `STACK_ROOT` | repository root |
| `MIGRATIONS_DIR` | this directory |
| `MIGRATION_ID` | manifest id |
| `SERVICE` | service directory |
| `RELEASE` | target version from the manifest |
| `KIND` | `preflight`, `window`, `post`, or `data` |
| `BACKUP_DIR` | per-run backup directory |
| `BACKUP_ROOT` | root that holds the per-run backup directories |
| `LOG_FILE` | per-run log file |

`lib.sh` provides `die`, `info`, `warn`, `service_env`, `compose_svc`,
`running_image_tag`, `assert_compose_image`, `compose_config_has`,
`compose_service_config_has`, `cidrs_include_ips`, `wait_http`, `wait_healthy`,
`container_status`, `backup_path`, and `require_tool`. Do not rely on the runner
sourcing it for you. `cidrs_include_ips` uses Python's standard-library
`ipaddress` module.

Rules:

1. **Idempotent.** A rerun after a partial failure must be safe. Detect the
   already-done state and exit zero.
2. **Verify, do not assume.** Read the running version, FCV, or schema before
   changing it, and fail when the starting state is wrong.
3. **Back up before destructive work.** Use `backup_path` for host paths, or the
   database's own dump tool for database paths. Write archives under
   `BACKUP_DIR`.
4. **No image edits.** Pins belong in compose files and pull requests. Scripts
   are allowed to check that the pin is already correct.
5. **Sequential.** Never skip an application or database major. Encode the
   expected previous version in a preflight script. The runner also requires
   earlier rows for the same service to be journalled before a later id runs.
6. **Small.** One migration does one thing. A ladder step gets its own id.

## Adding a migration

1. Add a preflight row for the starting state.
2. Add the data or window row, if the step needs one.
3. Add a post row that checks health and version.
4. Run `./stack migrate validate`.
5. Add a test fixture if the step introduces new runner behaviour.

`./stack migrate run <id>` records success in `${DATA_ROOT}/.migrations/<id>`.
Re-running a recorded step is a no-op unless `--force` is given.
