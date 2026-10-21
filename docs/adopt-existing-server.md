# Adopt an existing server

This runbook is for the reference server, which currently runs nginx and
per-service compose files under `~/<service>/`. Do not run it until the
follow-on plans have added every service to Traefik.

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
cp -a "$HOME/nginx/examples/user_conf.d" "$backup/nginx-user_conf.d"
sudo tar -C "$HOME/nginx/examples" -czf "$backup/letsencrypt.tgz" letsencrypt
docker volume ls > "$backup/docker-volumes.txt"
```

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

At the time of the eventual cutover, every listed service must already have a
Traefik route. Until then, leave nginx running and keep this list to the
services that have been migrated.

Copy each existing `~/<service>/.env` into `<service>/.env` and `<service>/.secrets`,
keeping the application's natural variable names and moving secrets into
`.secrets`. Do not commit either file.

Run:

```bash
./stack init
./stack check
```

## 3. Hardware transcoding

```bash
cp jellyfin/compose.override.yaml.example jellyfin/compose.override.yaml
```

Confirm the render device path exists.

## 4. Migrate old named volumes

If the old stack used named volumes, copy their contents into the bind paths
before starting the new compose files:

```bash
sudo mkdir -p /home/layz/authentik/database
docker run --rm \
  -v authentik_database:/from:ro \
  -v /home/layz/authentik/database:/to \
  alpine:3.20 sh -c 'cp -a /from/. /to/'
```

Repeat for `checkmate_mongo-data`, `tandoor_staticfiles`, and
`immich_model-cache`, using the corresponding `${DATA_ROOT}/<service>/...`
destination. Do not remove the old volumes until the new stack has been verified.

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

Do this only after every service has a Traefik route. Stop nginx without
removing data:

```bash
docker compose -f "$HOME/nginx/examples/docker-compose.yml" down
./stack up
```

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
docker compose -f "$HOME/jellyfin/docker-compose.yml" up -d
```

Keep the old compose files and nginx certificates until the new stack has been
stable for an agreed period.
