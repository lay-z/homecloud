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

Phase 2 converted Immich, Tandoor, Authentik, Papra, and Checkmate. Every public
service now has a Traefik route and bind-mounted data. nginx still owns ports 80
and 443; Phase 3 performs the ingress cutover and adds the update timer. Do not
stop nginx until the cutover is explicitly scheduled.

## Server notes

- SSH: `ssh homeserver`
- Current data root: `/home/layz`
- Current media path: `/mnt/seagate`
- Traefik and Checkmate use `/var/run/docker.sock:ro`; Authentik's worker uses it read-write as root. All are root-equivalent.
