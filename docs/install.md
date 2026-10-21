# Install

## Prerequisites

- Docker Engine with Compose v2
- `git`, `bash`, `openssl`, `curl`
- Public IP with inbound TCP 80 and 443
- A wildcard DNS record `*.<base-domain>` pointing at the host

## Install

```bash
git clone <repo> stack
cd stack
./stack init
```

Edit the root `.env`:

```dotenv
BASE_DOMAIN=example.com
ACME_EMAIL=you@example.com
DATA_ROOT=/srv/stack
TZ=Europe/London
PUID=1000
PGID=1000
ENABLED_SERVICES=jellyfin
```

Edit service values as needed:

```bash
$EDITOR jellyfin/.env
```

Run:

```bash
./stack init
./stack check
./stack up
```

## Verify

```bash
./stack status
curl -sI "https://flix.${BASE_DOMAIN}/" | head
docker logs traefik --tail=50
```

The first request may take a few seconds while Traefik obtains the certificate.

## Hardware transcoding

The base Jellyfin compose does not request `/dev/dri`. On hosts that have it:

```bash
cp jellyfin/compose.override.yaml.example jellyfin/compose.override.yaml
./stack up
```

Adjust the render device path if it is not `/dev/dri/renderD128`.
