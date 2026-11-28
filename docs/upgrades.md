# Upgrades and migrations

Last reviewed: 2026-11-23, on release `v0.4.0`.

This document is the upgrade plan for anything that cannot be handled by a
digest refresh. It records the shortest safe path for each service, the order
the steps must run in, and the migration tooling that enforces that order.

Pinned image changes still follow the normal release flow: a pull request, CI,
an annotated tag, then `./stack update`. The migration tooling in `migrations/`
only performs the data work that has to happen inside a maintenance window.

## Current versions

| Service | Pinned / running | Upstream | Next safe step |
| --- | --- | --- | --- |
| Traefik | 3.7.19 | 3.7.19 | none |
| Jellyfin | 10.11.11 | 12.4 | **12.4** (one hop, database migration) |
| Immich server / ML | v3.4.2 | v3.4.2 | none |
| Immich PostgreSQL | 14-vectorchord0.4.3 | upstream still pins 14 | stay on 14 |
| Valkey | 9 (`9.2.0`) | 9.2.0 | none (rolling major tag) |
| Tandoor Recipes | 2.7.6 | 2.7.6 | none |
| Papra | `latest` digest | rolling | digest refresh only |
| Checkmate | 4.1.0 | 4.1.0 | none |
| Checkmate Capture | 2.0.1 | 2.0.1 | none |
| MongoDB | 8.0.38, FCV 8.0 | 9.0.8 | **8.3** then **9.0** |
| Authentik | 2025.10.3 | 2026.8.6 | **2025.12.6**, then four-step ladder |
| PostgreSQL (Authentik, Tandoor) | 16.16 | 19 | stay on 16, optional later |

"Next safe step" means the smallest change that moves the service forward
without skipping a migration boundary.

## Why these are the shortest paths

- **Jellyfin 12.4** is the shortest path because upstream supports a direct
  upgrade from 10.10.7 and 10.11.x. No intermediate releases are required.
- **Authentik 2025.12.6** is the shortest path because Authentik requires
  sequential `major.minor` upgrades and forbids skipping. From 2025.10 the next
  stop is 2025.12, not 2026.8.
- **MongoDB 8.3** is the shortest path because MongoDB publishes a documented
  `8.0 -> 8.3` upgrade. From 8.3 the next stop is 9.0.
- **PostgreSQL 16 stays** because nothing in this stack requires 17, 18, or 19
  yet. PostgreSQL 16 is supported, and a major upgrade is a separate,
  optional maintenance project.
- **Immich PostgreSQL 14 stays** because Immich's own `docker-compose.yml` still
  pins the 14 image. Moving to 18 is possible, but it is not an upstream
  requirement and it carries extension-migration risk.

## Execution order

Run one application ladder at a time and finish it before starting another.
Suggested order, lowest risk first:

1. **MongoDB 8.0 -> 8.3** (Checkmate data only; reversible while FCV stays 8.0).
2. **Jellyfin 12.4** (single hop; irreversible, so back up first).
3. **Authentik 2025.12.6 -> 2026.8.6** (four deploys; the first one moves
   storage and enforces group-name uniqueness).
4. **MongoDB 8.3 -> 9.0** (only after Checkmate has run on 8.3 for a while;
   FCV 9.0 cannot be downgraded).
5. **PostgreSQL 19 / Immich PostgreSQL 18** (optional, separate project).

Do not batch several ladders into one maintenance window. Each step needs its
own backup, verification, and observation period.

## Structured migration process

Every migration has two halves.

**Release half** — a normal change to the repo:

```bash
git switch -c chore/<step>
# edit the image pin and any compose settings for that step
# run the tests
git commit
git push
# PR, CI, merge, tag, then on the server:
./stack update
```

**Data half** — a recorded migration, run in the maintenance window:

```bash
./stack migrate list
./stack migrate plan
./stack migrate run <id> --yes
./stack migrate status
```

`./stack migrate run` performs the same sequence every time:

1. checks the service is enabled and the migration is not already recorded;
2. checks free space on `DATA_ROOT` and `BACKUP_ROOT`;
3. requires `--yes` (or the migration id typed at a terminal);
4. stops the service when the manifest says it needs a stop;
5. runs the script with a per-run log and backup directory;
6. restarts the service;
7. writes a journal entry under `${DATA_ROOT}/.migrations/`.

If a script fails, the service is restarted on whatever is currently pinned,
the journal entry is **not** written, and the exit status is non-zero.

`./stack update` checks out the tag **and** restarts the stack, so after the
release half the new image is already serving. Every preflight therefore checks
the data state, not the image version, and may run before or after the deploy.
Preflights are skipped automatically once their id is journalled, so a re-run is
still a no-op.

The exception is a step whose data work must happen **before** the new image
starts. Jellyfin 12 is the only one today: check the tag out without deploying,
run the step, and let the runner start the new image itself.

```bash
git fetch --tags
git checkout v0.5.0        # no ./stack up yet
./stack migrate run jellyfin-12-preflight --yes
./stack migrate run jellyfin-12-migrate --yes   # stops 10.11, migrates offline, starts 12
./stack migrate run jellyfin-12-verify --yes
```

Do not use `./stack update` for that step; it would start Jellyfin 12 and run
the online migration the offline step exists to avoid.

### The manifest

`migrations/manifest.tsv` is the ordered list. Columns:

| Column | Meaning |
| --- | --- |
| `id` | stable name used on the command line |
| `service` | service directory and `ENABLED_SERVICES` entry |
| `release` | target application or database version |
| `kind` | `preflight`, `window`, `post`, or `data` |
| `needs_stop` | `yes` stops the service around the script |
| `backup` | `yes` marks the step as backup-bearing (documentation) |
| `min_free_mb` | free-space floor on both `DATA_ROOT` and `BACKUP_ROOT` |
| `script` | executable under `migrations/` |
| `description` | one line for `list` and `plan` |

`./stack migrate validate` checks the manifest and script permissions. Run it in
CI and before every release that adds a migration.

### Backups

Set `BACKUP_ROOT` in `.env` to a filesystem with room for a full copy:

```bash
BACKUP_ROOT=/mnt/seagate/backups
```

The default is `${DATA_ROOT}/backups`, which is usually the small root disk.
Each run gets `${BACKUP_ROOT}/<timestamp>-<id>/` with its own `SHA256SUMS`.
Keep the archive until the service has been stable for an agreed period.

### Rollback

- **Application step**: check out the previous tag and `./stack up`. This works
  only while the database has not passed an irreversible migration.
- **Authentik**: no downgrade support. Restore the PostgreSQL dump and the
  storage directory from the step's backup directory.
- **Jellyfin 12**: the database changes cannot be rolled back without a full
  config restore. Restore `jellyfin-config.tar.gz` before starting 10.11 again.
- **MongoDB**: a downgrade is possible only before the FCV is raised, and only
  to the immediately previous version. After FCV 9.0, restore the `mongodump`
  archive instead.
- **PostgreSQL major**: keep the old data directory until the new server has
  been verified. The logical dump is the portable fallback.

## Authentik ladder

Authentik must run every `major.minor` in sequence, with the latest patch in
each. Four deploys are required:

| Step | Image | Data work |
| --- | --- | --- |
| 1 | `2025.12.6` | group-name preflight, move `media/` to `data/media`, switch mount to `/data` |
| 2 | `2026.2.7` | application migrations only |
| 3 | `2026.5.8` | application migrations; verify the listen address still binds `127.0.0.1:9000` |
| 4 | `2026.8.6` | application migrations; verify trusted-proxy CIDRs, then `ANALYZE` |

Breakages to account for, from upstream release notes:

- **2025.12**: group names must be unique before the database migration, because
  the migration fails loudly on duplicates. File storage moves from `/media` to
  `/data`, and stored files are served from `/files` instead of `/media`. Group
  permissions and hierarchy change; review custom expression policies and
  property mappings.
- **2026.2**: SCIM group filters change and `User.ak_groups` is deprecated.
- **2026.5**: the default listen address changes from `0.0.0.0` to `[::]`.
  Verify the health check after this step. PostgreSQL connection options are
  deprecated.
- **2026.8**: forwarded headers are only honoured from trusted proxy networks.
  The defaults cover loopback and RFC1918, which is what Traefik uses here. If
  `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS` is set explicitly, it must include the
  Traefik source network.

Commands, once each release is deployed:

```bash
./stack migrate run authentik-2025.12-preflight --yes
./stack migrate run authentik-2025.12-storage --yes
./stack migrate run authentik-2025.12-verify --yes
# repeat for 2026.2, 2026.5, and 2026.8
./stack migrate run authentik-2026.8-analyze --yes
```

The 2025.12 release PR must make three changes together:

1. Change the storage mount from `${DATA_ROOT}/authentik/media:/media` to
   `${DATA_ROOT}/authentik/data:/data`, on both the `server` and the `worker`
   service in `authentik/compose.yaml`.
2. Add `$DATA_ROOT/authentik/data` to the directories `cmd_init` creates in
   `stack`. Without it, a fresh install gets no `data/` directory, Docker
   creates it as `root:root`, and Authentik (uid 1000 in the image) cannot
   write to it. `./stack check` now fails on a missing bind source under
   `DATA_ROOT`, so shipping one change without the other blocks the deploy
   instead of failing later at upload time.
3. Keep the mount and `init` changes in the same release tag: `./stack update`
   checks out and deploys in one step, and refuses a dirty tree, so there is no
   way to patch the host between releases.

The storage migration refuses to run until the mount change is in the
checked-out compose file.

## Jellyfin 12

Jellyfin 12 changes the database in a way that prevents rolling back without a
full restore. Upstream supports a direct upgrade from 10.11.x, and provides an
offline migration mode, which the tooling uses.

Current preflight result on the reference server:

- No usernames differ only by case.
- Three repository plugins are installed: `Discogs`, `Open Subtitles`, and
  `SSO Authentication`. They must be moved aside before the migration and
  reinstalled in a 12-compatible version afterwards.

```bash
mkdir -p "$DATA_ROOT/jellyfin/plugins-pre-12"
find "$DATA_ROOT/jellyfin/config/plugins" -mindepth 1 -maxdepth 1 -type d \
  ! -name configurations -exec mv {} "$DATA_ROOT/jellyfin/plugins-pre-12/" +

./stack migrate run jellyfin-12-preflight --yes
./stack migrate run jellyfin-12-migrate --yes
./stack migrate run jellyfin-12-verify --yes
```

Check the tag out before the first command and do not run `./stack update`
until the ladder is finished; see [Structured migration process](#structured-migration-process).
Keep `configurations/` in place (the preflight ignores it); only the plugin
directories have to move.

The migration step archives the whole config directory, then runs
`jellyfin --mode MigrateSystem` without serving requests. The runner then starts
Jellyfin 12.4. After verification, run a full library scan; Jellyfin 12 requires
it to rebuild alternative versions.

## MongoDB / Checkmate

MongoDB upgrades are two operations: new binaries, then a feature compatibility
version (FCV) change. FCV is the point of no return.

| Step | Image | Required starting state | FCV after |
| --- | --- | --- | --- |
| 1 | `mongo:8.3` | 8.0 binaries, FCV 8.0 | 8.3 |
| 2 | `mongo:9.0` | 8.3 binaries, FCV 8.3 | 9.0 |

The upgrade script takes a `mongodump` archive before raising the FCV. Checkmate
officially targets `mongo:8.0`, so run 8.3 for a few days before 9.0 and watch
the Checkmate logs and uptime history.

```bash
./stack migrate run checkmate-mongo-8.3-preflight --yes
./stack migrate run checkmate-mongo-8.3 --yes
# after an observation period
./stack migrate run checkmate-mongo-9.0-preflight --yes
./stack migrate run checkmate-mongo-9.0 --yes
```

## Deferred work

### PostgreSQL 16 -> 19

Not required by any service. PostgreSQL 16 remains supported. When it is
scheduled, use a logical dump and restore rather than swapping the image:

1. Take a `pg_dumpall --clean --if-exists` archive of the service database.
2. Stop the service.
3. Keep the old data directory, for example `database.pre-pg19-<timestamp>`.
4. Start the new PostgreSQL with an empty data directory and restore into
   `postgres`.
5. Verify the application, then keep the old directory until the next backup.

Do not run pg_upgrade directly against the bind-mounted directory without
verifying that both versions are available in the same image.

### Immich PostgreSQL 14 -> 18

Immich still ships PostgreSQL 14 in its own compose file, and its documentation
states that major upgrades are not just an image change. If it is done later,
dump with `pg_dumpall --clean --if-exists`, restore into the new image, and
verify that the VectorChord extension is present before starting Immich. The
`-upgrade` image variants exist for controlled `pg_upgrade` flows; the plain
logical dump is easier to audit.

### Rolling tags

`papra`, `vabene1111/recipes`, and the Checkmate images use `latest` with a
digest pin. Renovate can only refresh the digest, so the release notes for the
new digest must be read before merging. Prefer switching these to version tags
when upstream publishes stable, sortable tags.

## Disk budget

The reference server had roughly 5 GB free on `/` before this plan was written,
and image pulls once filled it during a deployment. Before each maintenance
window:

```bash
df -h / "$DATA_ROOT" "$BACKUP_ROOT"
docker system df
docker image prune -a          # only after confirming no rollback needs the old images
```

Keep `BACKUP_ROOT` on the large disk. A Jellyfin config archive is about 1 GB and
an Immich database dump is about 1 GB; the root filesystem cannot hold both plus
new image layers.

## Verification checklist

For every step:

- [ ] `./stack migrate run` exited zero and the journal entry exists
- [ ] the service reports healthy in `./stack status`
- [ ] the application logs contain no migration or database errors
- [ ] the public route returns HTTP 200
- [ ] the application can still write its data, not just serve it: for Authentik
      2025.12 upload a file so `/data` is exercised, for Jellyfin check a new
      library item, for Immich an upload
- [ ] the backup directory contains a verified archive and `SHA256SUMS`
- [ ] the step is left to run for an observation period before the next one
