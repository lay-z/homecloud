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

## Optional automatic updates

The repo ships opt-in systemd user units that run `./stack update` daily:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/stack-update.service systemd/stack-update.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now stack-update.timer
loginctl enable-linger "$USER"
```

The units assume the checkout is `~/stack`; edit `WorkingDirectory` and
`ExecStart` otherwise. The timer is not enabled by default.

## Container update notifications

Add `wud` and `authentik` to `ENABLED_SERVICES` to receive Telegram alerts when
an upstream image publishes a new build. `./stack init` generates the shared
OIDC client in the root `.env`; the Authentik provider and application come
from `authentik/blueprints/wud.yaml`. See
[operations.md](operations.md#update-notifications).

## Hardware transcoding

The base Jellyfin compose does not request `/dev/dri`. On hosts that have it:

```bash
cp jellyfin/compose.override.yaml.example jellyfin/compose.override.yaml
./stack up
```

Adjust the render device path if it is not `/dev/dri/renderD128`.
