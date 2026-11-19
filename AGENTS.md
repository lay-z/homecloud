# homelab-stack

This repo is the source of truth for the Docker Compose stack. `stack` is the
operator interface; Traefik provides ingress and certificates from container
labels.

## Commands

```bash
./stack init
./stack check
./stack up
./stack status
./stack logs <service>
./stack update
./stack doctor
```

## Layout

- `<service>/compose.yaml`: service stack, explicit `name:`
- `<service>/.env`: service values (gitignored)
- `<service>/.secrets`: service secrets, mode 0600 (gitignored)
- `<service>/compose.override.yaml`: host-specific overrides (gitignored)
- root `.env`: instance values (gitignored)
- `tools/dns/`: optional Namecheap tooling

Persistent data lives under `${DATA_ROOT}/<service>`, outside the repo. All
persistent paths are bind mounts; do not introduce named or anonymous volumes.
`stack check` rejects `type: volume`, and `stack down -v` is rejected.

## Current phase

Phase 3 is complete on the reference server. Traefik owns ports 80 and 443 and
serves every public service from its per-service stack. nginx is stopped; the
old compose files, old named volumes, and `~/nginx` remain the rollback path
until the migration has been stable for an agreed period. The opt-in
`stack-update.timer` lives in `systemd/` and is not installed by default.

## Server notes

- SSH: `ssh homeserver`
- Current data root: `/home/layz`
- Current media path: `/mnt/seagate`
- Traefik and Checkmate use `/var/run/docker.sock:ro`; Authentik's worker uses it read-write as root. All are root-equivalent.
- Docker Engine 29 rejects old API clients; Traefik must stay at v3.6 or newer.
- The update timer runs as a systemd user unit and needs docker group access.
