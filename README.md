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
| WUD | `wud.<base>` | `127.0.0.1:3000` | monitoring |

All public services are converted to per-service directories. Traefik owns ports
80 and 443. On the reference server nginx is stopped; the old stacks, old named
volumes, and `~/nginx` are kept as the rollback path.

## Updates

```bash
git fetch --tags
./stack update
```

Automatic updates are opt-in. Install the user units once, using the checkout
path in `WorkingDirectory` / `ExecStart` if it is not `~/stack`:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/stack-update.service systemd/stack-update.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now stack-update.timer
loginctl enable-linger "$USER"   # runs without an active login session
```

The timer runs `./stack update` daily around 04:00 with up to an hour of random
delay. Disable it with `systemctl --user disable --now stack-update.timer`.

Rollback is `git checkout <previous-tag> && ./stack up`. Back up
`${DATA_ROOT}`, the root `.env`, and all `*/.env` / `*/.secrets` files before
updating. Database migrations may not be reversible.

## Update notifications

`stack update` only moves the repo between release tags. Because every image is
pinned as `tag@sha256`, a plain `docker compose pull` downloads nothing new.

`wud` reports what upstream has published instead. Enable it by adding `wud`
and `authentik` to `ENABLED_SERVICES`, adding the Telegram credentials to
`wud/.secrets`, then running `./stack init` and `./stack up`:

```dotenv
ENABLED_SERVICES=jellyfin,immich,tandoor,authentik,papra,checkmate,wud
```

```bash
$EDITOR wud/.secrets   # append BOTTOKEN and CHATID, see the commented example
./stack init           # creates ${DATA_ROOT}/wud/store
./stack up
```

Append both Telegram values; with them missing WUD simply runs without a
Telegram trigger. `GET https://api.telegram.org/bot<token>/getUpdates` returns
the chat ID after you send the bot a message.

WUD checks registries every six hours (`WUD_WATCHER_LOCAL_CRON` in
`wud/.env`) and sends one batched Telegram message per detection cycle.
Digest watching is on, so same-tag rebuilds such as `latest@sha256` and
`16-alpine` are reported too. Each service carries a `wud.link.changelog`
label, so every line in the message links to that project's release notes.
For one message a week instead, set the cron to `0 9 * * 1` and add
`WUD_WATCHER_LOCAL_WATCHEVENTS=false`.

### WUD sign-in through Authentik

WUD uses native OIDC, not Traefik forward auth. The client credentials live
once in the root `.env` (`WUD_OIDC_CLIENT_ID`, `WUD_OIDC_CLIENT_SECRET`) and
`./stack init` generates them if they are empty. The Authentik side is declared
in `authentik/blueprints/wud.yaml`, which Authentik discovers under
`/blueprints/custom` and applies on its own; the OAuth2 provider, the
application, and the policy binding are never clicked into the admin UI.

Only members of `authentik Admins` can sign in, and
`WUD_AUTH_OIDC_AUTHENTIK_ADMINGROUP` maps that group to WUD's admin role.
Rotate the client secret by changing it in the root `.env`, touching
`authentik/blueprints/wud.yaml` so Authentik applies it again, and running
`./stack up`.

## Dependency updates

Image pins change by pull request, not by hand. The scheduled workflow runs
weekly on Monday and opens grouped PRs: digest and patch bumps together, minors
separately, majors held for a checkbox on the dependency dashboard. Renovate has
no schedule of its own, so a manual dispatch acts immediately.

The workflow in `.github/workflows/renovate.yml` is inert until a token exists:

```bash
gh secret set RENOVATE_TOKEN   # fine-grained PAT: Contents RW, Pull requests RW, Issues RW
gh workflow run renovate.yml
```

A PAT is required instead of the workflow token because PRs opened with
`GITHUB_TOKEN` do not trigger CI, and every pin bump must pass the render tests.
Alternatively, install the Mend-hosted Renovate app on the repository and
delete the workflow; public repositories are free.

Merging a PR does not deploy anything. Tag the release and update the server:

```bash
gh pr merge --squash --delete-branch
git switch main && git pull --ff-only
git tag -a v0.4.0 -m "v0.4.0" && git push origin v0.4.0
ssh homeserver 'cd ~/stack && ./stack update'
```

Rollback is `git checkout <previous-tag> && ./stack up` on the server. Read a
major bump's release notes before merging it: Authentik, Immich, Tandoor, and
Checkmate can change database schemas, and an image rollback does not undo a
migration.

Images pinned as `latest@sha256` (Papra, Tandoor, Checkmate) can only receive
digest updates, because the tag itself carries no version. That is expected.

## Data safety

Every persistent path is a bind mount under `${DATA_ROOT}/<service>`. No service
uses a named or anonymous data volume. `stack down` rejects `-v` and
`--volumes`, and `stack check` fails if a rendered mount has `type: volume`.
`docker compose down -v` and volume pruning therefore cannot remove application
data. Back up `${DATA_ROOT}` separately; bind mounts do not protect against
`rm -rf`. Jellyfin media and Immich uploads (for example `/mnt/seagate`) are
outside `${DATA_ROOT}` and need separate backups.

## Notes

- `tools/dns/` contains optional Namecheap DNS tooling for the reference
  deployment. It is not required to use this stack.
- `docs/install.md`, `docs/operations.md`, and `docs/adopt-existing-server.md`
  cover the details.
- Never commit `.env`, `*/.env`, `*/.secrets`, `.namecheap.env`,
  `*/compose.override.yaml`, or `*/compose.staging.yaml`.
