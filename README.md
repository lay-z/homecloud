# homelab-stack

Repo-owned Docker Compose stack with Traefik ingress, per-instance env files,
and a small `stack` CLI. Each service is a directory containing its compose
file and local env files.

## Requirements

- Linux host with Docker Engine and Compose v2
- git and bash
- Ports 80 and 443 free
- DNS wildcard `*.<base-domain>` pointing at the host

## Quick start

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

`./stack init` creates the root `.env` and the per-service env files on the
first run. Edit them, run `init` again to create data directories and
`acme.json`, then `check` and `up`.

Do not fork or use this as a template if you want upstream updates. Clone the
repo directly; `.env`, `*/.env`, and `*/.secrets` are ignored, so pulls never
conflict. Put local values in those files. If you edit tracked files,
`stack update` will refuse to run.

## Layout

```text
.
├── .env                 # instance values
├── stack
├── traefik/compose.yaml
├── jellyfin/
│   ├── compose.yaml
│   ├── .env
│   └── .secrets
└── ...
```

Persistent data lives under `${DATA_ROOT}/<service>`, never inside the repo.

## Commands

```text
./stack init                 Create env files and required directories
./stack check                Validate env files and compose configuration
./stack up                   Start Traefik and enabled services
./stack down                 Stop services and Traefik (keeps data)
./stack status               Show container status
./stack logs <service>       Follow logs
./stack restart <service>    Restart a service
./stack update [--version v] Check out a release tag and redeploy
./stack doctor               Print redacted diagnostics
```

## Services

| Service | Domain | Upstream | Status |
| --- | --- | --- | --- |
| Jellyfin | `flix.<base>` | `127.0.0.1:8096` | converted |
| Immich | `photos.<base>` | `127.0.0.1:2283` | converted |
| Tandoor | `recipes.<base>` | `127.0.0.1:8979` | converted |
| Authentik | `id.<base>` | `127.0.0.1:9000` | converted |
| Papra | `docs.<base>` | `127.0.0.1:1221` | converted |
| Checkmate | `status.<base>` / `info.status.<base>` | `127.0.0.1:52345` | converted |

All public services are converted to per-service directories. nginx still owns
ports 80 and 443 until Phase 3 cuts ingress over to Traefik.

## Updates

```bash
git fetch --tags
./stack update
```

Rollback is `git checkout <previous-tag> && ./stack up`. Back up
`${DATA_ROOT}`, the root `.env`, and all `*/.env` / `*/.secrets` files before
updating. Database migrations may not be reversible.

## Data safety

Every persistent path is a bind mount under `${DATA_ROOT}/<service>`. No service
uses a named or anonymous data volume. `stack down` rejects `-v` and
`--volumes`, and `stack check` fails if a rendered mount has `type: volume`.
`docker compose down -v` and volume pruning therefore cannot remove application
data. Back up `${DATA_ROOT}` separately; bind mounts do not protect against
`rm -rf`.

## Notes

- `tools/dns/` contains optional Namecheap DNS tooling for the reference
  deployment. It is not required to use this stack.
- `docs/install.md`, `docs/operations.md`, and `docs/adopt-existing-server.md`
  cover the details.
- Never commit `.env`, `*/.env`, `*/.secrets`, `.namecheap.env`, or
  `*/compose.override.yaml`.
