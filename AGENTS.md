# priyav.dev infrastructure

This repo holds DNS tooling for `priyav.dev`; the server context below is here so
future sessions can work on the box without rediscovering it.

## Access

- SSH: `ssh homeserver` (alias for `flix.priyav.dev`, user `layz`).
- Everything runs in Docker. Per-service stacks live in `~/<service>/` with a
  `docker-compose.yml` (e.g. `~/jellyfin`, `~/immich`, `~/tandoor`, `~/authentik`,
  `~/papra`, `~/checkmate`).
- Reverse proxy: container `examples-nginx-1`, image `jonasal/nginx-certbot`,
  `network_mode: host`. Config and certs are bind-mounted from `~/nginx/examples/`.

## DNS routing

Two hosts, split at DNS using the Namecheap tool in this repo:

- Wildcard `*.priyav.dev` → server A (`212.132.249.106`), the Docker/nginx box.
- `assets.priyav.dev` → server B (`2a01:4f8:1c1b:d23d::1`), a separate host running
  Snipe-IT behind Caddy + Apache. It is NOT on `homeserver`.
- More-specific records beat the wildcard; see `README.md` for the `set` pattern.
- New subdomains on server A normally need no DNS change. Verify with
  `dig +short <domain>` before touching Namecheap.

## Service map

All upstreams below are reached from nginx over `127.0.0.1:<port>` because the
proxy uses the host network.

| Domain | Upstream / container | Notes |
| --- | --- | --- |
| `flix.priyav.dev` | `127.0.0.1:8096` / `jellyfin` | Jellyfin |
| `photos.priyav.dev` | `127.0.0.1:2283` / `immich_server` | Immich |
| `recipes.priyav.dev` | `127.0.0.1:8979` / `tandoor-web_recipes-1` | Tandoor (container port 80) |
| `id.priyav.dev` | `127.0.0.1:9000` / `authentik-server-1` | Authentik (worker + postgresql in same compose) |
| `docs.priyav.dev` | `127.0.0.1:1221` / `papra` | Papra |
| `status.priyav.dev` | `127.0.0.1:52345` / `checkmate` | Checkmate admin UI |
| `info.status.priyav.dev` | `127.0.0.1:52345` / `checkmate` | Checkmate public status page |
| `assets.priyav.dev` | server B | Snipe-IT, not on this host |

## Nginx and certificates

- Site configs: `~/nginx/examples/user_conf.d/*.conf` on `homeserver`.
- Certs: `/etc/letsencrypt/live/<name>/` inside the container. `<name>` comes from
  the `ssl_certificate` path in the site config, not necessarily the domain, so use
  a sensible name like `live/info.status/`.
- Certbot runs at container start. After adding or changing a site config, run
  `docker restart examples-nginx-1` to trigger certificate issuance and the reload.
- DNS must already point at the box before certbot runs (HTTP-01 via webroot).
- Useful checks:
  - `docker exec examples-nginx-1 ls -la /etc/letsencrypt/live/`
  - `docker logs examples-nginx-1 --tail 50`
  - `curl -sI https://<domain>/`

## Secrets

Never commit credentials. DNS creds live in `.namecheap.env`; certbot settings in
`~/nginx/examples/nginx-certbot.env`; per-service secrets in each stack's `.env`.
