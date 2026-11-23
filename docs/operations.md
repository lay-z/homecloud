# Operations

## Daily commands

```bash
./stack status
./stack logs jellyfin
./stack restart jellyfin
./stack down
./stack up
```

`down` never removes data, and `stack down -v` is rejected.

## Data safety

All persistent data is bind-mounted under `${DATA_ROOT}`. There are no named or
anonymous data volumes. `docker compose down -v`, `docker volume prune`, and
`docker system prune --volumes` cannot remove bind-mounted data. Run
`./stack check` to verify that no rendered mount has `type: volume`.

Bind mounts do not protect against `rm -rf ${DATA_ROOT}` or disk failure. Keep
independent backups.

## Migrating existing named volumes

Run only the block for the service being swapped; do not run all four at once.
Do not stop all four volume owners together; stopping Authentik early breaks
Papra OIDC logins. Restart or swap the service immediately after its block; do
not leave it down.

Stop the owning container before copying. The tool refuses a non-empty
destination. If a copy fails partway, remove only that failed partial copy;
never delete a populated destination.

```bash
set -euo pipefail
set -a
. ./.env
set +a
: "${DATA_ROOT:?run from the repo root with .env loaded}"

# Immich
docker stop --time 60 immich_machine_learning
./tools/migrate-volume.sh immich_model-cache "$DATA_ROOT/immich/model-cache"
```

```bash
set -euo pipefail
set -a
. ./.env
set +a
: "${DATA_ROOT:?run from the repo root with .env loaded}"

# Tandoor
docker stop --time 60 tandoor-web_recipes-1
./tools/migrate-volume.sh tandoor_staticfiles "$DATA_ROOT/tandoor/staticfiles"
```

```bash
set -euo pipefail
set -a
. ./.env
set +a
: "${DATA_ROOT:?run from the repo root with .env loaded}"

# Checkmate
docker stop --time 60 checkmate-mongodb-1
./tools/migrate-volume.sh checkmate_mongo-data "$DATA_ROOT/checkmate/mongo-data"
```

```bash
set -euo pipefail
set -a
. ./.env
set +a
: "${DATA_ROOT:?run from the repo root with .env loaded}"

# Authentik
docker stop --time 60 authentik-postgresql-1
./tools/migrate-volume.sh authentik_database "$DATA_ROOT/authentik/database"
```

Immich's Redis data is a pure cache. Start it with an empty
`${DATA_ROOT}/immich/redis` instead of copying the anonymous volume.
Checkmate's `/data/configdb` volume is empty; create
`${DATA_ROOT}/checkmate/mongo-configdb` and leave it empty.

Do not delete the old volumes until the new containers have been running and
verified for an agreed period.

## Updates

```bash
git fetch --tags
./stack update
```

Pin the version with:

```bash
./stack update --version v0.2.0
```

Rollback:

```bash
git checkout <previous-tag>
./stack up
```

Back up `${DATA_ROOT}`, the root `.env`, and all `*/.env` / `*/.secrets` files
first. Database migrations may not be reversible.

### Optional update timer

The units in `systemd/` run `./stack update` daily at 04:00 with up to an hour
of random delay. They are not installed automatically.

```bash
mkdir -p ~/.config/systemd/user
cp systemd/stack-update.service systemd/stack-update.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now stack-update.timer
loginctl enable-linger "$USER"
```

The units assume the checkout is `~/stack`; edit `WorkingDirectory` and
`ExecStart` otherwise. Check the result with
`systemctl --user list-timers stack-update.timer` and
`journalctl --user -u stack-update.service`.

## Update notifications

`stack update` swaps repo release tags; it never pulls upstream images on its
own, because every image is pinned as `tag@sha256`. WUD fills that gap by
watching the registries and reporting new upstream builds.

Enable `wud` and `authentik` in `ENABLED_SERVICES`, then:

```bash
$EDITOR wud/.secrets    # WUD_TRIGGER_TELEGRAM_NOTIFY_BOTTOKEN / CHATID
./stack init
./stack up
```

`wud/.env` holds the check cadence (`WUD_WATCHER_LOCAL_CRON`, six-hourly by
default) and `WUD_WATCHER_LOCAL_WATCHDIGESTDEFAULT=true`, which is what catches
rebuilds of pinned tags such as `latest@sha256`. Notifications are batched into
one Telegram message per detection cycle, and every service's
`wud.link.changelog` label supplies a release-notes link.

For a single weekly message, set `WUD_WATCHER_LOCAL_CRON=0 9 * * 1` and
`WUD_WATCHER_LOCAL_WATCHEVENTS=false`, so only the scheduled check — not a
container restart — can surface a new image.

Check the Last Check column in the UI, or:

```bash
./stack logs wud
curl -s http://127.0.0.1:3000/health
```

### Sign-in through Authentik

WUD authenticates users with OIDC against Authentik. The client is shared
through the root `.env`:

```dotenv
WUD_OIDC_CLIENT_ID=...
WUD_OIDC_CLIENT_SECRET=...
```

`./stack init` generates both when empty, so a fresh install needs no manual
step. `authentik/blueprints/wud.yaml` declares the OAuth2 provider, the `wud`
application, and a policy binding restricting access to `authentik Admins`.
Authentik mounts that directory at `/blueprints/custom` and applies it
automatically; the file is re-applied when it changes or on the periodic scan.

To rotate the secret, change `WUD_OIDC_CLIENT_SECRET` in the root `.env`, touch
the blueprint so Authentik applies it again, and recreate the services:

```bash
touch authentik/blueprints/wud.yaml
./stack up
```

If sign-in fails, check that the blueprint applied
(`docker logs authentik-worker-1 --tail=50`) and that the `wud` application
appears under Authentik's Applications.

## Backups

Back up these separately:

- `${DATA_ROOT}`: application data and databases
- `/mnt/seagate`: Jellyfin media and Immich uploads
- root `.env`
- every `*/.env`
- every `*/.secrets`
- `${DATA_ROOT}/traefik/acme.json`

The repo itself contains no persistent data.

## TLS

Traefik stores ACME state in `${DATA_ROOT}/traefik/acme.json` (mode 0600).
Certificates are requested per host by HTTP-01, so inbound port 80 must be
reachable and DNS must already point at the host.

## Troubleshooting

```bash
./stack check
./stack doctor
docker logs traefik --tail=100
docker compose ls
```

If a service returns 502, confirm its loopback port is listening:

```bash
ss -ltnp | grep 8096
```

## Security

Traefik and Checkmate mount the Docker socket read-only; Authentik's worker
mounts it read-write and runs as root for outpost management. All three are
root-equivalent on the host. Do not run untrusted containers. Do not expose the
Traefik dashboard.
