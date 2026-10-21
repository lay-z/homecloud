# Repo-owned deployment architecture

- **Status:** Proposed
- **Date:** 2026-10-21
- **Scope:** `priyav.dev` server A, plus a distributable layout for other owners
- **Supersedes:** the current split between `~/<service>/docker-compose.yml`,
  `~/nginx/examples/`, and this repo's DNS-only tooling

## Context

Today the server is configured by hand: each service has its own compose file and
`.env` under `~/<service>/`, nginx site files live under `~/nginx/examples/`, and
this repo only contains Namecheap DNS tooling. There is no single source of truth
and no repeatable way to deploy the same stack to another server.

The goal is a repo that is the source of truth for server configuration and the
mechanism for updates. It must work for:

- the current server, without losing existing data;
- friends and family, who need simple updates;
- people the maintainer has never met, who can clone the repo, set their own
  domain and secrets, and receive upstream fixes without the maintainer having
  access to their server or knowledge of their instance.

The base domain must be an instance value. Service subdomains are fixed:
`flix`, `photos`, `recipes`, `id`, `docs`, `status`, and `info.status`. Changing
the base domain must not require editing templates or compose files.

## Goals

1. One git repo contains all server configuration: compose files, ingress rules,
   helper script, and documentation.
2. A fresh instance is configured with a root env file, per-service env files,
   and a single command.
3. Updates are `git pull` plus a deploy command; local configuration never
   conflicts with upstream changes.
4. The current server can adopt the repo with its existing volumes and data.
5. No central controller, no telemetry, and no maintainer SSH access to other
   instances.
6. Minimal runtime dependencies: Docker Engine, Docker Compose v2, git, bash.
7. Traefik provides ingress and certificates from compose labels. There is no
   nginx config templating and no certbot sidecar.

## Non-goals (v1)

- Automatic/scheduled updates (the design supports adding a systemd timer).
- Automated application/database backups.
- Multi-host orchestration or a web control plane.
- Managing DNS through arbitrary registrars.
- Snipe-IT on server B (`assets.priyav.dev`) and stacks not listed in scope
  (including Sonarr).
- Custom service prefixes.
- Rootless Docker or Podman.

## Decisions

| Decision           | Choice                                                                    |
| ------------------ | ------------------------------------------------------------------------- |
| Ingress            | Traefik v3 via Docker provider and compose labels                         |
| TLS                | Traefik ACME HTTP-01, per-host certificates, `acme.json`                  |
| Configuration      | Per-service compose + local env; root `.env` for instance values          |
| Instance tool      | Small dependency-free bash `stack` script                                 |
| Deployment         | Manual `git pull` + `./stack up`; systemd timer later                     |
| Fleet upgrade path | Plain Compose remains compatible with Komodo                              |
| Base domain        | Install-time value; derived in labels and env interpolation               |
| Secrets            | Per-service `.secrets`, mode 0600, never tracked                          |
| Image versions     | Pinned by tag or digest in tracked compose files; no `latest`             |
| Data location      | `${DATA_ROOT}/<service>/...` bind mounts + preserved project names        |
| Data safety        | No named/anonymous data volumes; `down -v` cannot remove bind mounts      |
| Repo               | Public `homelab-stack` (working name); current tree becomes the repo root |

## Repository layout

```text
.
├── stack                       # bash CLI: init, check, up, down, status, update, doctor
├── traefik/
│   └── compose.yaml
├── jellyfin/
│   ├── compose.yaml
│   ├── .env.example            # tracked, documented service inputs
│   ├── .env                    # ignored, service values
│   ├── .secrets.example        # tracked, key names only
│   └── .secrets                # ignored, 0600
├── immich/
│   └── ...                     # same shape
├── tandoor/
│   └── ...
├── authentik/
│   └── ...
├── papra/
│   └── ...
├── checkmate/
│   └── ...
├── docs/
│   ├── install.md
│   ├── adopt-existing-server.md
│   ├── operations.md
│   └── superpowers/specs/      # design documents
├── tests/
├── tools/
│   └── dns/namecheap_dns.py    # optional, current-owner tooling
├── .env.example                # tracked, documented instance inputs
├── .env                        # ignored, instance values
├── .gitignore
└── README.md
```

`.env` and `*/.env` / `*/.secrets` are gitignored; the example files are tracked.
No persistent data lives inside the repo. All service data is under
`${DATA_ROOT}/<service>`.

There is no service catalog and no generated-config directory. Each service
directory is the definition of its service. `ENABLED_SERVICES` in the root
`.env` controls which services `stack` starts. Traefik is always started.

`tools/dns/` is optional. Other owners are not required to use Namecheap.

## Domain model

`.env` contains a bare domain:

```dotenv
BASE_DOMAIN=example.com
ACME_EMAIL=admin@example.com
```

Everything else is derived at Compose evaluation time:

- Traefik rules: ``Host(`flix.${BASE_DOMAIN}`)``
- App URLs: `https://flix.${BASE_DOMAIN}`, and so on
- Certificate subjects: obtained by Traefik from the router host rule

Fixed prefixes:

| Service | Public host | Upstream | Notes |
| --- | --- | --- | --- |
| Jellyfin | `flix.<base>` | `127.0.0.1:8096` | media server |
| Immich | `photos.<base>` | `127.0.0.1:2283` | photos |
| Tandoor | `recipes.<base>` | `127.0.0.1:8979` | container port 80 |
| Authentik | `id.<base>` | `127.0.0.1:9000` | SSO |
| Papra | `docs.<base>` | `127.0.0.1:1221` | documents |
| Checkmate | `status.<base>` | `127.0.0.1:52345` | admin UI |
| Checkmate | `info.status.<base>` | `127.0.0.1:52345` | public status page |

`assets.<base>` is not managed here; it points at server B.

No tracked compose, script, or env template may hardcode a service domain; all
domains derive from `BASE_DOMAIN`. CI renders with `BASE_DOMAIN=example.test` and
asserts the expected hosts. Documentation may reference the reference deployment.

## Configuration and secrets

Configuration is split by ownership, not variable prefix. All files are local
and gitignored unless they end in `.example`.

- Root `.env` — instance-wide non-secret values: `BASE_DOMAIN`, `ACME_EMAIL`,
  `DATA_ROOT`, `TZ`, `PUID`, `PGID`, `ENABLED_SERVICES`.
- `<service>/.env` — non-secret service values using the names the application
  expects, for example `JELLYFIN_MEDIA_PATH`.
- `<service>/.secrets` — service secrets, mode `0600`.

Every service directory has both `.env.example` and `.secrets.example`; the
secrets template may be empty for services that need no secrets. Traefik is the
exception: it uses the root `.env` for `ACME_EMAIL` and has no service env files.

There are no namespace prefixes. Variables such as `DB_PASSWORD`,
`POSTGRES_PASSWORD`, and `SECRET_KEY` are scoped to the service that owns them
because each service is its own Compose project and its own file set.

`stack` passes the layers in order:

```bash
cd <service>
docker compose \
  --env-file "$REPO/.env" \
  --env-file .env \
  --env-file .secrets \
  -f compose.yaml ...
```

Later files override earlier ones. Service files must not define the reserved
instance keys (`BASE_DOMAIN`, `ACME_EMAIL`, `DATA_ROOT`, `ENABLED_SERVICES`);
`stack check` enforces this.

Compose files use the service env files for container environment:

```yaml
env_file:
  - .env
  - .secrets
```

and use `${BASE_DOMAIN}` / `${DATA_ROOT}` for interpolation. Do not put
`${BASE_DOMAIN}` inside a service `.env` or `.secrets`: Compose `env_file` does
not interpolate values, so the container would receive the literal string.
Derived URLs belong in the compose `environment:` block.

`./stack init`:

1. Copies the root `.env.example` to `.env` if missing.
2. For each service directory, copies `.env.example` to `.env` and
   `.secrets.example` to `.secrets` if missing.
3. Generates missing secret values from the keys in each `.secrets.example` and
   sets mode `0600`.
4. Creates `${DATA_ROOT}/<service>` directories and
   `${DATA_ROOT}/traefik/acme.json`, but never changes ownership silently.
5. Prints the required DNS records.

Existing hardcoded secrets in current compose files move into the owning
service's `.secrets`. Any secret that has ever been committed or shared outside
the host should be rotated during adoption.

## Volumes and data preservation

Service directories contain code and local configuration only. Persistent data
lives outside the git clone and every persistent path is an explicit bind mount:

```yaml
volumes:
  - ${DATA_ROOT}/immich/postgres:/var/lib/postgresql/data
  - ${DATA_ROOT}/immich/uploads:/data
```

There is no `data/` directory or data symlink inside a service directory. This
keeps the clone disposable: `git clean`, re-cloning, or moving the repo cannot
delete application data.

`DATA_ROOT` is `/home/layz` on the current server and `/srv/stack` by default for
new installs.

### Data safety rule

No compose file may declare a top-level `volumes:` section, and no persistent
path may be a named or anonymous volume. This matters because
`docker compose down -v`, `docker compose down --volumes`, `docker volume prune`,
and `docker system prune --volumes` remove named and anonymous volumes. They do
not remove bind mounts.

Every path that must survive a restart, a `down -v`, or volume pruning is a bind
mount under `${DATA_ROOT}/<service>`. That includes:

- application databases (Postgres, MongoDB)
- uploads and media libraries managed by the app
- generated state that should survive (for example Tandoor static files)
- caches that are expensive to rebuild (for example Immich model cache)
- `traefik/acme.json`

If an image declares a `VOLUME` for a path the service needs, mount that path
explicitly as a bind. Do not rely on anonymous volumes.

Guardrails:

- `stack down` rejects `-v` and `--volumes` with an explicit error.
- `stack check` renders each service with `docker compose config --format json`
  and fails if any mount has `"type": "volume"`.
- CI runs the same check.
- Existing named volumes are migrated to bind mounts during adoption.

`docker compose down -v` is therefore safe for data in this repo, though
`stack down` never passes it. Bind mounts do not protect against
`rm -rf ${DATA_ROOT}` or disk failure; backups are still required.

Every compose file sets an explicit top-level project name:

```yaml
name: immich
```

This preserves container and network identity during adoption. Existing named
volumes are copied into their bind-mount paths before the new compose files are
started. List them and verify mounts with:

```bash
docker volume ls
docker compose config
```

`stack down` never passes `-v`. Direct `docker compose down -v` is data-safe for
these bind mounts, but it is not part of normal operations and can still remove
anonymous volumes.

## Ingress and TLS

Traefik runs as its own Compose project, with host networking so it can reach
loopback-published app ports and see client addresses.

Static configuration:

- entrypoints `web` (:80) and `websecure` (:443)
- global HTTP-to-HTTPS redirect
- Docker provider, `exposedByDefault=false`
- ACME HTTP-01 resolver using `${ACME_EMAIL}`
- storage at `${DATA_ROOT}/traefik/acme.json`, bind-mounted with mode `0600`
- dashboard disabled

Per-service labels follow this shape:

```yaml
labels:
  traefik.enable: "true"
  traefik.http.routers.flix.rule: "Host(`flix.${BASE_DOMAIN}`)"
  traefik.http.routers.flix.entrypoints: "websecure"
  traefik.http.routers.flix.tls.certresolver: "le"
  traefik.http.services.flix.loadbalancer.server.url: "http://127.0.0.1:8096"
```

Application ports bind to loopback:

```yaml
ports:
  - "127.0.0.1:2283:2283"
```

This prevents bypassing TLS by hitting the container port directly. Jellyfin uses
bridge networking and a loopback-published port by default. Host networking is an
opt-in override for DLNA, documented as an exposure risk.

Nginx-specific behavior maps to Traefik middleware:

- body-size limits: buffering middleware
- Jellyfin CSP/security headers: headers middleware
- websockets: handled automatically
- redirects: static entrypoint redirect

`acme.json` must be mode `0600` and included in host backups. Certificates are
per-host, so no wildcard certificate or DNS-01 provider credentials are needed.

## Deployment flow

### Fresh install

```bash
git clone <repo> stack
cd stack
./stack init
$EDITOR .env
$EDITOR jellyfin/.env
./stack init
./stack check
./stack up
```

Prerequisites: Docker Engine, Compose v2, git, bash, ports 80/443 free, and DNS
for `<base>` and `*.<base>` pointing at the host.

Clone the upstream repo directly; do not fork or use a template if you want
upstream updates. `.env`, `*/.env`, and `*/.secrets` are ignored, so pulls remain
conflict-free. Do not edit tracked files for local preferences: put instance
values in the root `.env`, service values in `<service>/.env`, and secrets in
`<service>/.secrets`. Upstream changes that every instance should receive.
`stack update` refuses to run with a dirty tree to prevent silent drift.

### Checks

`./stack check` validates:

- root `.env` exists and is readable;
- `BASE_DOMAIN` is a bare domain with no scheme, path, or trailing slash;
- `ENABLED_SERVICES` contains known services and their dependencies;
- each enabled service has `.env`, and `.secrets` when its
  `.secrets.example` exists;
- service files do not define reserved instance keys;
- secret files are mode `0600` and required keys are non-empty;
- `${DATA_ROOT}/<service>` exists;
- each enabled service passes `docker compose config -q` from its directory;
- no rendered mount has `"type": "volume"` (named or anonymous volumes are
  rejected);
- no compose or script file hardcodes a service domain;
- required host directories and ports are available, with warnings where a
  failure may be intentional.

### Up

`./stack up`:

1. Starts Traefik.
2. Iterates over `ENABLED_SERVICES` and, from each service directory, runs:
   ```bash
   docker compose \
     --env-file "$REPO/.env" \
     --env-file .env \
     --env-file .secrets \
     -f compose.yaml \
     up -d --remove-orphans
   ```
3. Prints the public URLs and container status.

Traefik discovers new labels, requests certificates, and starts routing.

### Update

`./stack update`:

1. Refuses if tracked files are modified.
2. Fetches tags and checks out the requested stable release tag (or the newest
   stable tag by default).
3. Runs `check` and `up`.
4. Reports the previous tag so an operator can roll back.

Rollback is `git checkout <previous-tag> && ./stack up`. Data is untouched, but
database migrations may make rollback unsafe. Stateful updates should be
preceded by a backup; automated backups are out of scope for v1.

### Later: unattended updates

Add an opt-in systemd service and timer:

```text
stack-update.service -> ./stack update
stack-update.timer   -> daily, randomized delay
```

The timer is not installed by default. `stack update` remains the single update
path, so adding the timer does not change the model.

### Later: Komodo

The repo is already compatible with Komodo's Compose stacks: plain compose files,
externalized env, explicit project names. If the fleet grows, Komodo can point at
the repo and manage the stacks without restructuring. It is not required for v1.

## Adoption plan for the current server

The cutover is a one-time operation with a maintenance window. Containers can
keep running; only ingress is interrupted.

1. **Back up.** Capture `docker compose config` for every stack, all compose and
   env files, nginx site configs, `/etc/letsencrypt`, and database dumps
   (`pg_dump`, `mongodump`) or volume snapshots. Never commit these backups.
2. **Create the instance.** Clone the repo to a working directory. Copy existing
   `~/<service>/.env` values into `<service>/.env` and `<service>/.secrets`,
   splitting secrets from non-secrets but keeping the application's natural
   variable names. Put shared values (`BASE_DOMAIN`, `ACME_EMAIL`, `DATA_ROOT`,
   `TZ`, `PUID`, `PGID`, `ENABLED_SERVICES`) in the root `.env`. Generate only
   genuinely new secrets.
3. **Rewrite compose files.** Add `name:`, replace relative mounts with
   `${DATA_ROOT}/<service>/...`, move secrets out, add Traefik labels, bind ports
   to loopback, pin image tags or digests.
4. **Migrate named volumes.** Copy the contents of existing named volumes into
   their `${DATA_ROOT}/<service>/...` bind-mount paths. This applies at least to
   Authentik's `database`, Checkmate's `mongo-data`, Tandoor's `staticfiles`, and
   Immich's `model-cache`. Do not leave persistent data in a removable volume.
5. **Validate without starting.** Run `docker compose config` for each stack and
   compare project names, mounts, and ports with the running system. Confirm no
   rendered mount has `"type": "volume"`.
6. **Stage ingress.** Start Traefik on alternate ports (for example 8080/8443)
   with TLS disabled or a staging ACME resolver, or with temporary host rules.
   Verify routing to each upstream while nginx still owns 80/443.
7. **Cut over.** Stop the nginx container, start Traefik on 80/443, and let it
   issue certificates. Verify each public URL and an Authentik login.
8. **Keep rollback.** Leave the nginx container and its certs intact (stopped)
   until every service has been stable for an agreed period.
9. **Publish.** Remove tracked secrets, rotate anything that was exposed, and
   only then push the repo publicly.

Expected downtime: ingress only during the nginx-to-Traefik swap, plus container
recreation where env or network settings changed. Plan the window accordingly.

## Security

- Docker socket access is root-equivalent. Traefik needs it for label discovery;
  document this clearly. A socket proxy can be added later.
- Traefik dashboard stays disabled or bound to loopback only.
- App ports bind to `127.0.0.1`.
- Per-service `.secrets` files are `0600` and excluded from git.
- No telemetry, no central access, no maintainer-held SSH keys for other
  instances.
- Image versions are pinned; `latest` is not allowed. Release tags are immutable.
- `stack doctor` redacts secret values.
- Public repo: assume all tracked files are public. Never commit secrets; avoid
  personal paths and IPs in compose/scripts. Documentation may describe the
  reference deployment.

## Testing and CI

- `shellcheck` on `stack`.
- `docker compose config -q` for every service with a synthetic root `.env` and
  synthetic per-service `.env`/`.secrets`, using `BASE_DOMAIN=example.test`.
- Assert rendered output contains `flix.example.test` and friends.
- Assert every rendered mount is a bind mount, not `"type": "volume"`.
- Assert no compose or script file contains the production base domain or a
  known secret value.
- Optional `bats` tests for `stack` argument handling and env parsing.
- CI does not deploy; deployment remains a server-side action.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Traefik socket access is root-equivalent | Read-only mount, no dashboard, document; socket proxy later |
| Old named volumes are missed during adoption | List `docker volume ls`, copy contents to bind paths, verify before cutover |
| Relative mounts move | All mounts use `${DATA_ROOT}`; compare `docker compose config` |
| Losing existing secrets | Back up env files; move values before first start |
| Image updates break an app | Pin versions; update deliberately; keep previous tag |
| DB migration prevents rollback | Back up stateful services before updates |
| `down -v` or volume pruning deletes data | All persistent paths are bind mounts; `stack check` rejects `type: volume`; `stack down` rejects `-v` |
| ACME rate limits during cutover | Test with staging resolver; use production once |
| Port 80 blocked or proxied | ACME HTTP-01 requires inbound 80; document, and consider DNS-01 later |
| CGNAT / no public IP | Out of scope; users need a public IP or a tunnel |
| No wildcard DNS for users | Print required records; wildcard is recommended |
| Local env deleted by a re-clone or `git clean` | Back up root `.env`, `*/.env`, and `*/.secrets`; docs warn against destructive cleanup |
| Public repo leaks data | CI grep for domains/secrets; review before publish |

## Future work

- systemd timer for opt-in automatic updates.
- Optional Komodo adoption for a larger fleet.
- Automated backups and pre-update hooks.
- `BASE_DOMAIN` migration tooling (explicitly out of scope for v1).
- DNS provider adapters.
- Optional per-instance prefix overrides.
- Snipe-IT/server B integration, if desired.

## Implementation note

The current working tree is not yet a git repository. Initializing it, moving the
existing DNS tool to `tools/dns/`, creating the real service directories, and
publishing under the working repo name are implementation steps, not part of this
design.
