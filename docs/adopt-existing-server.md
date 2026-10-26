# Adopt an existing server

This runbook is for the reference server, which currently runs nginx and
per-service compose files under `~/<service>/`. All services are already
converted to Traefik routes. Sections 1-5 and 9 are Phase 2; sections 6-8 are
Phase 3. Complete section 9 for every service before section 6.

## 1. Back up

```bash
set -euo pipefail
umask 077
backup="$HOME/backups/stack-$(date +%F-%H%M%S)"
mkdir -p "$HOME/backups"
mkdir "$backup"
chmod 700 "$backup"

for service in jellyfin immich tandoor authentik papra checkmate; do
  file="$HOME/$service/docker-compose.yml"
  [[ -f "$file" ]] || file="$HOME/$service/docker-compose.yaml"
  docker compose -f "$file" config > "$backup/$service.compose.resolved.yml"
  cp "$file" "$backup/$service.compose.yml"
  cp "$HOME/$service/.env" "$backup/$service.env"
done

sudo tar -C /home/layz -czf "$backup/data-root.tgz" \
  jellyfin immich tandoor authentik papra checkmate traefik

docker exec authentik-postgresql-1 pg_dump -U authentik authentik > "$backup/authentik.sql"
docker exec tandoor-db_recipes-1 pg_dump -U djangouser djangodb > "$backup/tandoor.sql"
docker exec immich_postgres pg_dump -U postgres immich > "$backup/immich.sql"
docker exec checkmate-mongodb-1 mongodump --archive --gzip > "$backup/checkmate-mongo.archive.gz"

nginx_file="$HOME/nginx/examples/docker-compose.yml"
[[ -f "$nginx_file" ]] || nginx_file="$HOME/nginx/examples/docker-compose.yaml"
cp "$nginx_file" "$backup/nginx-compose.yml"
cp -a "$HOME/nginx/examples/user_conf.d" "$backup/nginx-user_conf.d"
sudo tar -C "$HOME/nginx/examples" -czf "$backup/letsencrypt.tgz" letsencrypt

if [[ -f "$HOME/stack/.env" ]]; then
  cp "$HOME/stack/.env" "$backup/stack.env"
fi

docker volume ls > "$backup/docker-volumes.txt"
sudo chmod -R go-rwx "$backup"
```

The backup directory name includes seconds, and `mkdir` fails if the directory
already exists. Any failure stops the block. `chmod -R go-rwx` protects database
passwords, env files, resolved configs, and ACME keys.

If the backup fails, stop and fix it before continuing.

The SQL dumps and Mongo archive are the consistent database backups.
`data-root.tgz` is a best-effort filesystem copy of bind data taken while
services run. For a fully consistent database backup, stop the old services
first or rely on the dumps above. The retained old named volumes and bind
mounts are the migration rollback path; do not treat the live tar as a
database-consistent backup.

Never commit the backup directory.

## 2. Prepare the instance

```bash
set -euo pipefail
REPO_URL=<repo-url>
if [[ -e "$HOME/stack" ]]; then
  printf '%s already exists; move it aside or update it manually\n' "$HOME/stack" >&2
  exit 1
fi
git clone "$REPO_URL" "$HOME/stack"
cd "$HOME/stack"
cp -n .env.example .env
```

Set at least:

```dotenv
BASE_DOMAIN=priyav.dev
ACME_EMAIL=<your email>
DATA_ROOT=/home/layz
PUID=1000
PGID=1000
ENABLED_SERVICES=jellyfin,immich,tandoor,authentik,papra,checkmate
```

All six services are migrated and have Traefik routes. Keep nginx running until
Phase 3; do not cut over ingress yet.

Create `<service>/.env` and `<service>/.secrets` from the templates. Copy
existing non-secret values into `.env` and existing secrets into `.secrets`.
Set `IMMICH_UPLOAD_LOCATION` to the old `UPLOAD_LOCATION`. `chmod 600` each
`.secrets`. Do not let `./stack init` generate replacements for existing
secrets. Do not commit either file.

After populating them, back up the new repo `.env` and each service `.env` and
`.secrets` into the section 1 backup directory, using `$backup` from that shell.

Run `./stack init` and `./stack check` after the files are populated.

## 3. Hardware transcoding

```bash
cp -n jellyfin/compose.override.yaml.example jellyfin/compose.override.yaml
```

Confirm the render device path exists.

## 4. Migrate old named volumes

Run only the block for the service being swapped; do not run all four at once.
Do not stop all four volume owners together; stopping Authentik early breaks
Papra OIDC logins.

Stop the owning container, then copy its volume into the bind path. Never pass
`-v` to `docker compose down`. The tool refuses a non-empty destination. If a
copy fails partway, remove only that failed partial copy; never delete a
populated destination.

```bash
set -euo pipefail
set -a
. ./.env
set +a
: "${DATA_ROOT:?run from the repo root with .env loaded}"
```

```bash
# Immich
docker stop --time 60 immich_machine_learning
./tools/migrate-volume.sh immich_model-cache "$DATA_ROOT/immich/model-cache"
```

```bash
# Tandoor
docker stop --time 60 tandoor-web_recipes-1
./tools/migrate-volume.sh tandoor_staticfiles "$DATA_ROOT/tandoor/staticfiles"
```

```bash
# Checkmate
docker stop --time 60 checkmate-mongodb-1
./tools/migrate-volume.sh checkmate_mongo-data "$DATA_ROOT/checkmate/mongo-data"
```

```bash
# Authentik
docker stop --time 60 authentik-postgresql-1
./tools/migrate-volume.sh authentik_database "$DATA_ROOT/authentik/database"
```

Create empty directories for the disposable data:

```bash
mkdir -p /home/layz/immich/redis /home/layz/checkmate/mongo-configdb
```

Immich uploads (`/mnt/seagate/Media/Photos`), Immich Postgres
(`/home/layz/immich/postgres`), Jellyfin media (`/mnt/seagate`), Tandoor
Postgres/media, Authentik media/certs/templates, and Papra app-data are already
bind mounts and need no copy. Set `IMMICH_UPLOAD_LOCATION` to the old
`UPLOAD_LOCATION` value (`/mnt/seagate/Media/Photos` on the reference server),
and move the old `DB_PASSWORD` into `immich/.secrets`, not `immich/.env`.

Put existing secrets in each service's `.secrets`, not `.env`; `--env-file`
order makes `.secrets` win, and `stack check` validates it.

For Papra, set `PAPRA_OIDC_CLIENT_ID` to the existing client ID and preserve
`AUTH_SECRET` in `papra/.secrets` so existing sessions stay valid. Rotate only
the OIDC client secret in Authentik, immediately before the Papra swap, and put
the new URL-safe secret in `papra/.secrets`.

For Checkmate, preserve `ENCRYPTION_KEY` and `CAPTURE_API_SECRET`. Generate a
new `JWT_SECRET` with `openssl rand -hex 32` and put them in
`checkmate/.secrets`; do not reuse the exposed JWT secret. The capture service
maps `CAPTURE_API_SECRET` to `API_SECRET`.

For Tandoor, move the existing `SECRET_KEY`, `POSTGRES_PASSWORD`, and
`EMAIL_HOST_PASSWORD` into `tandoor/.secrets`. The Postgres container must use
the same `POSTGRES_PASSWORD` as the existing database.

For Authentik, move the existing `PG_PASS` and `AUTHENTIK_SECRET_KEY` into
`authentik/.secrets`. The Postgres container must use the same `PG_PASS` as the
existing database.

Do not remove the old volumes until the new stack has been verified.

## 5. Verify data paths

The new Jellyfin compose uses:

- `${DATA_ROOT}/jellyfin/config` -> `/config`
- `${DATA_ROOT}/jellyfin/cache` -> `/cache`
- `${JELLYFIN_MEDIA_PATH}` -> `/media`

These must match the old container's mounts. Check with:

```bash
docker inspect jellyfin --format '{{json .Mounts}}' | python3 -m json.tool
```

**Phase 3 only. Do not run sections 6-8 until section 9 is complete for every
service.**

## 6. Cut over ingress (Phase 3)

Do this only after section 9 is complete for every service. Run `./stack check`
before stopping nginx:

```bash
./stack check
nginx_file="$HOME/nginx/examples/docker-compose.yml"
[[ -f "$nginx_file" ]] || nginx_file="$HOME/nginx/examples/docker-compose.yaml"
docker compose -f "$nginx_file" down
./stack up
```

Do not stop an old project after its new project is running. Both use the same
project name, so `docker compose down` would remove the new containers.

## 7. Verify (Phase 3)

```bash
for host in flix photos recipes id docs status info.status; do
  printf '%s: ' "$host"
  curl -s -o /dev/null -w '%{http_code}\n' "https://$host.priyav.dev/"
done
docker logs traefik --tail=100
```

Verify an Authentik login and one Jellyfin playback.

## 8. Rollback (Phase 3)

Rollback starts the old stacks on the old volumes. Named-volume services
(Authentik database, Checkmate Mongo, Tandoor static files, Immich model cache)
lose post-swap writes on rollback because the old volumes do not contain them.
Bind-mounted services share the same paths, so their post-swap writes remain.
If writes to a named volume are needed, copy the bind path back into the old
volume before starting the old stack; otherwise accept the loss.

If Papra was swapped and the OIDC client secret was rotated:

- Full rollback including Authentik: the old Authentik still has the old OIDC
  secret, so keep the old Papra secret.
- Papra-only rollback while new Authentik remains: update the old Papra compose
  or env with the new OIDC secret.
- If you copy the new Authentik bind data back into the old volume, update old
  Papra to the new secret.

```bash
set -euo pipefail
./stack down

for service in jellyfin immich tandoor authentik papra checkmate; do
  file="$HOME/$service/docker-compose.yml"
  [[ -f "$file" ]] || file="$HOME/$service/docker-compose.yaml"
  docker compose -f "$file" up -d
done

nginx_file="$HOME/nginx/examples/docker-compose.yml"
[[ -f "$nginx_file" ]] || nginx_file="$HOME/nginx/examples/docker-compose.yaml"
docker compose -f "$nginx_file" up -d
```

Keep the old compose files and nginx certificates until the new stack has been
stable for an agreed period.

## 9. Soft-swap one service at a time (Phase 2)

This step keeps nginx on 80/443 and swaps the container behind nginx. It is the
safe way to validate each converted stack before Phase 3. Run the commands from
the repo root (`$HOME/stack`).

For every Phase 2 service, plus the Jellyfin soft-swap:

1. Migrate only the volumes for this service using the matching pair in
   section 4, immediately before the swap.
2. Stop the old project without removing data:

   ```bash
   file="$HOME/<service>/docker-compose.yml"
   [[ -f "$file" ]] || file="$HOME/<service>/docker-compose.yaml"
   docker compose -f "$file" down
   ```

3. Start only the converted service from this repo. Add
   `-f <service>/compose.override.yaml` when that file exists. Do not run
   `./stack up` during the Phase 2 soft swaps; section 6 is the Phase 3
   cutover.
4. Verify the public URL still works through nginx.

Checkmate's old file is `docker-compose.yaml`; the others are
`docker-compose.yml`.

Example for Jellyfin:

```bash
cp -n jellyfin/compose.override.yaml.example jellyfin/compose.override.yaml
docker compose -f "$HOME/jellyfin/docker-compose.yml" down
docker compose --env-file .env --env-file jellyfin/.env --env-file jellyfin/.secrets -f jellyfin/compose.yaml -f jellyfin/compose.override.yaml up -d
curl -sI https://flix.priyav.dev/ | head
```

Example for Immich:

```bash
docker compose -f "$HOME/immich/docker-compose.yml" down
docker compose --env-file .env --env-file immich/.env --env-file immich/.secrets -f immich/compose.yaml up -d
curl -sI https://photos.priyav.dev/ | head
```

Tandoor, Authentik, and Papra follow the same pattern with `docker-compose.yml`
and no host override in this phase.

Example for Checkmate:

```bash
cp -n checkmate/compose.override.yaml.example checkmate/compose.override.yaml
docker compose -f "$HOME/checkmate/docker-compose.yaml" down
docker compose --env-file .env --env-file checkmate/.env --env-file checkmate/.secrets -f checkmate/compose.yaml -f checkmate/compose.override.yaml up -d
curl -sI https://status.priyav.dev/ | head
```

The Checkmate override is only needed if group 957 owns the Docker socket.

`docker compose -f` does not auto-merge `compose.override.yaml`; pass it
explicitly when present.

Recommended order for the five Phase 2 services, lowest risk first:

1. Immich (photos and Postgres already bind-mounted; only caches change)
2. Tandoor (Postgres and media already bind-mounted; static files copy)
3. Checkmate (Mongo data copy)
4. Authentik (Postgres data copy; verify login before moving on)
5. Papra (no data move)

Jellyfin is already converted; use it as a first soft-swap validation if
desired.

### Validate through Traefik without touching nginx

Do not run `./stack up` until Phase 3. To prove Traefik can serve a converted
service while nginx still owns 80/443, run a second Traefik on 8080/8443.

Create `traefik/compose.staging.yaml` (gitignored) with:

```yaml
name: traefik-staging
services:
  traefik:
    container_name: traefik-staging
    restart: "no"
    command:
      - --global.checkNewVersion=false
      - --global.sendAnonymousUsage=false
      - --entrypoints.web.address=:8080
      - --entrypoints.websecure.address=:8443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --providers.docker=true
      - --providers.docker.exposedByDefault=false
      - --providers.docker.endpoint=unix:///var/run/docker.sock
      - --certificatesresolvers.le.acme.email=${ACME_EMAIL}
      - --certificatesresolvers.le.acme.storage=/acme.json
      - --certificatesresolvers.le.acme.caServer=https://acme-staging-v02.api.letsencrypt.org/directory
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
      - --api.dashboard=false
      - --log.level=INFO
      - --accesslog=false
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${DATA_ROOT}/traefik/acme-staging.json:/acme.json
```

Use a separate ACME file so staging writes cannot disturb production state:

```bash
set -a
. ./.env
set +a

touch "$DATA_ROOT/traefik/acme-staging.json"
chmod 600 "$DATA_ROOT/traefik/acme-staging.json"
```

Start it and probe the Host header:

```bash
docker compose -p traefik-staging --env-file .env -f traefik/compose.yaml -f traefik/compose.staging.yaml up -d
curl -sk -H 'Host: flix.priyav.dev' https://127.0.0.1:8443/ -o /dev/null -w '%{http_code}\n'
```

Expect 200, 302, 401, or 403; a 404 can mean the router is missing or the app
has no route at `/`; verify a known application path. Certificate issuance
cannot succeed while nginx owns port 80; `-k` accepts Traefik's fallback
certificate. Repeat with each migrated Host. Then stop the staging instance and
remove the staging override and staging ACME file:

```bash
docker compose -p traefik-staging --env-file .env -f traefik/compose.yaml -f traefik/compose.staging.yaml down && {
  set -a
  . ./.env
  set +a
  rm traefik/compose.staging.yaml "$DATA_ROOT/traefik/acme-staging.json"
}
```

If an earlier attempt left `traefik/compose.override.yaml`, remove it before
Phase 3 with `rm traefik/compose.override.yaml`; `stack` auto-includes it.

Rollback for a single service. Writes made to the new bind mounts after the
swap are not copied back. If those writes are needed, copy the bind path back
into the old volume before starting the old stack; otherwise accept the loss.

For Papra: if new Authentik remains, update the old Papra compose or env with
the new OIDC secret. If you also roll back Authentik, the old Authentik still
has the old secret, so keep the old Papra secret. If you copy the new Authentik
bind data back into the old volume, update old Papra to the new secret.

Stop the new project
(`docker compose --env-file .env --env-file <service>/.env --env-file <service>/.secrets -f <service>/compose.yaml down`)
and start the old one:

```bash
set -euo pipefail
file="$HOME/<service>/docker-compose.yml"
[[ -f "$file" ]] || file="$HOME/<service>/docker-compose.yaml"
docker compose -f "$file" up -d
```

Do not run `./stack up` or `./stack down` during Phase 2; use the per-service
commands, because both operate on the whole stack and can remove still-running
old services. Do not run `./stack down -v`. Do not stop nginx until the Phase 3
cutover in section 6.
