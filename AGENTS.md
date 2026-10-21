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

Jellyfin is the first converted service. Other services and the nginx cutover
are follow-on work. Do not stop nginx until every public host has a Traefik
route.

## Server notes

- SSH: `ssh homeserver`
- Current data root: `/home/layz`
- Current media path: `/mnt/seagate`
- Traefik uses `/var/run/docker.sock:ro`; this is root-equivalent.
