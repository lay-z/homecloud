# Adopt an existing server

This runbook is for the reference server, which currently runs nginx and
per-service compose files under `~/<service>/`. All services are already
converted to Traefik routes. This runbook stops before the Phase 3 ingress
cutover.

## 1. Back up

```bash
backup="$HOME/backups/stack-$(date +%F-%H%M)"
mkdir -p "$backup"
for service in jellyfin immich tandoor authentik papra checkmate; do
  file="$HOME/$service/docker-compose.yml"
  [[ -f "$file" ]] || file="$HOME/$service/docker-compose.yaml"
  docker compose -f "$file" config \
    > "$backup/$service.compose.resolved.yml" 2>/dev/null || true
  cp "$file" "$backup/" 2>/dev/null || true
  cp "$HOME/$service/.env" "$backup/$service.env" 2>/dev/null || true
done
sudo tar -C /home/layz -czf "$backup/data-root.tgz" \
  jellyfin immich tandoor authentik papra checkmate 2>/dev/null || true
cp -a "$HOME/nginx/examples/user_conf.d" "$backup/nginx-user_conf.d"
sudo tar -C "$HOME/nginx/examples" -czf "$backup/letsencrypt.tgz" letsencrypt
docker volume ls > "$backup/docker-volumes.txt"
```

The old named volumes are retained and are the rollback copy for named-volume
services; do not delete them until verification.

Never commit the backup directory.

## 2. Prepare the instance

```bash
git clone <repo> "$HOME/stack"
cd "$HOME/stack"
cp .env.example .env
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

Run `./stack init` and `./stack check` after the files are populated.

## 3. Hardware transcoding

```bash
cp jellyfin/compose.override.yaml.example jellyfin/compose.override.yaml
```

Confirm the render device path exists.

## 4. Migrate old named volumes

Run only the stop and copy pair for the service being swapped. Do not stop all
four at once: Authentik and Papra are dependencies for other services' logins.

Stop the owning container, then copy its volume into the bind path. Never pass
`-v` to `docker compose down`. The tool refuses a non-empty destination. If a
copy fails partway, remove only that failed partial copy; never delete a
populated destination.

```bash
docker stop --time 60 authentik-postgresql-1
./tools/migrate-volume.sh authentik_database /home/layz/authentik/database

docker stop --time 60 tandoor-web_recipes-1
./tools/migrate-volume.sh tandoor_staticfiles /home/layz/tandoor/staticfiles

docker stop --time 60 checkmate-mongodb-1
./tools/migrate-volume.sh checkmate_mongo-data /home/layz/checkmate/mongo-data

docker stop --time 60 immich_machine_learning
./tools/migrate-volume.sh immich_model-cache /home/layz/immich/model-cache
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

## 6. Cut over ingress

Do this only after section 9 is complete for every service. Stop nginx without
removing data:

```bash
docker compose -f "$HOME/nginx/examples/docker-compose.yml" down
./stack up
```

Do not stop an old project after its new project is running. Both use the same
project name, so `docker compose down` would remove the new containers.

## 7. Verify

```bash
for host in flix photos recipes id docs status info.status; do
  printf '%s: ' "$host"
  curl -s -o /dev/null -w '%{http_code}\n' "https://$host.priyav.dev/"
done
docker logs traefik --tail=100
```

Verify an Authentik login and one Jellyfin playback.

## 8. Rollback

```bash
./stack down

docker compose -f "$HOME/nginx/examples/docker-compose.yml" up -d

for service in jellyfin immich tandoor authentik papra checkmate; do
  file="$HOME/$service/docker-compose.yml"
  [[ -f "$file" ]] || file="$HOME/$service/docker-compose.yaml"
  docker compose -f "$file" up -d
done
```

Rollback starts the old stacks on the old volumes. Writes made to the new bind
mounts after the swap are not copied back. If those writes are needed, copy the
bind path back into the old volume before starting the old stack; otherwise
accept the loss.

Keep the old compose files and nginx certificates until the new stack has been
stable for an agreed period.

## 9. Soft-swap one service at a time

This step keeps nginx on 80/443 and swaps the container behind nginx. It is the
safe way to validate each converted stack before Phase 3. Run the commands from
the repo root (`$HOME/stack`).

For every service:

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
   `./stack up`; that starts Traefik on ports 80 and 443 and would conflict
   with nginx.
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

`docker compose -f` does not auto-merge `compose.override.yaml`; pass it
explicitly when present.

Recommended order, lowest risk first:

1. Immich (photos and Postgres already bind-mounted; only caches change)
2. Tandoor (Postgres and media already bind-mounted; static files copy)
3. Checkmate (Mongo data copy)
4. Authentik (Postgres data copy; verify login before moving on)
5. Papra (no data move)

### Validate through Traefik without touching nginx

Do not run `./stack up` until Phase 3. To prove Traefik can serve a converted
service while nginx still owns 80/443, run a second Traefik on 8080/8443.

Create `traefik/compose.staging.yaml` (gitignored) with:

```yaml
services:
  traefik:
    container_name: traefik-staging
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

Expect 200, 302, 401, or 403; a 404 means the router is missing. Certificate
issuance cannot succeed while nginx owns port 80; `-k` accepts Traefik's
fallback certificate. Repeat with each migrated Host. Then stop the staging
instance and remove the override and staging ACME file:

```bash
docker compose -p traefik-staging --env-file .env -f traefik/compose.yaml -f traefik/compose.staging.yaml down
rm traefik/compose.staging.yaml "$DATA_ROOT/traefik/acme-staging.json"
```

Rollback for a single service: stop the new project
(`docker compose --env-file .env --env-file <service>/.env --env-file <service>/.secrets -f <service>/compose.yaml down`)
and start the old one:

```bash
file="$HOME/<service>/docker-compose.yml"
[[ -f "$file" ]] || file="$HOME/<service>/docker-compose.yaml"
docker compose -f "$file" up -d
```

Writes made to the new bind mounts after the swap are not copied back. If those
writes are needed, copy the bind path back into the old volume before starting
the old stack; otherwise accept the loss.

Do not run `./stack down -v`. Do not stop nginx in this phase.
