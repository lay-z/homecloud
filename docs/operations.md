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

## Backups

Back up these separately:

- `${DATA_ROOT}`: application data and databases
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

Traefik and Checkmate mount the Docker socket read-only, but that is still
root-equivalent on the host. Do not run untrusted containers. Do not expose the
Traefik dashboard.
