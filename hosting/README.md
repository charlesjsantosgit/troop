# TROOP dedicated server hosting

This directory documents the checked-in deployment scaffold for one always-on
Godot 4.7 server on Fly.io. After deployment is explicitly enabled, GitHub
Actions builds the Linux dedicated export in `Dockerfile` and deploys it
whenever server-relevant files reach `main`.

The service exposes ENet on **UDP 30623**. Players do not host a server, forward
a home-router port, or need Fly credentials.

## Dedicated-server integration contract

The checked-in game code implements the contract used by the container:

1. `OS.get_cmdline_user_args()` recognizes the `server` argument used by the
   container and starts networking without spawning peer `1` as a player,
   building a local HUD, or waiting in the main menu.
2. On Fly, the server resolves the `TROOP_BIND_IP` environment value
   (`fly-global-services`) and passes that address to
   `ENetMultiplayerPeer.set_bind_ip()` before `create_server()`. It reads
   `TROOP_SERVER_PORT`, currently `30623`, for the ENet port.
3. The dedicated peer owns the roster and shared claims and explicitly relays
   validated client-originated gameplay and voice packets.

Fly's public UDP proxy requires the application to bind to
`fly-global-services` on the same internal and external port. A wildcard bind is
not a supported substitute. See [Fly's UDP documentation](https://fly.io/docs/networking/udp-and-tcp/)
and [Godot's ENet bind API](https://docs.godotengine.org/en/4.7/classes/class_enetmultiplayerpeer.html#class-enetmultiplayerpeer-method-set-bind-ip).

## One-time Fly setup

Install `flyctl`, sign in, then choose a globally unique lowercase app name. The
example region in `fly.toml` is `sjc`; change `primary_region` before the first
deployment if most initial players are closer to another [Fly region](https://fly.io/docs/reference/regions/).

```bash
fly auth login
fly apps create YOUR_FLY_APP_NAME
fly ips allocate-v4 -a YOUR_FLY_APP_NAME
fly tokens create deploy -a YOUR_FLY_APP_NAME -x 720h
```

A dedicated public IPv4 address is mandatory for Fly UDP services. It is a paid
resource; Fly does not route public UDP over its shared IPv4 or public IPv6
addresses. Confirm the allocation with:

```bash
fly ips list --app YOUR_FLY_APP_NAME
```

The 30-day token lifetime above is intentionally finite. Rotate it before it
expires, or choose a different lifetime that matches the release process. Use an
app-scoped deploy token, not a personal or organization-wide token.

## GitHub Actions secrets

In the GitHub repository, open **Settings > Secrets and variables > Actions**
and add these repository or `production` environment secrets:

- `FLY_APP_NAME`: the exact Fly app name.
- `FLY_API_TOKEN`: the full app-scoped deploy token returned by `flyctl`.

After the app, dedicated IPv4 address, and secrets exist, add the repository
Actions variable `FLY_DEPLOY_ENABLED=true`. Until that explicit switch is set,
push-triggered deployment jobs are skipped instead of failing or creating cloud
resources prematurely.

The workflow passes the app name with `--app`, so `fly.toml` contains no account
identifier or credential. A push to `main` that changes a server-relevant path
starts `.github/workflows/deploy-server.yml`; it can also be started manually
with **Run workflow**. It deploys with `--ha=false` because two independent
authoritative Machines behind one UDP endpoint would split players into
different sessions. If this app was deployed before this workflow was added,
explicitly scale it to one Machine once:

```bash
fly scale count 1 --app YOUR_FLY_APP_NAME
```

Fly's official [GitHub Actions deployment guide](https://fly.io/docs/launch/continuous-deployment-with-github-actions/)
describes the same token and remote-build flow.

## Public endpoint injected into player builds

The stable player endpoint is:

```text
YOUR_FLY_APP_NAME.fly.dev:30623 (UDP)
```

The hostname and port are public configuration, not secrets. Add the GitHub
Actions variable `TROOP_PUBLIC_SERVER_HOST` with
`<FLY_APP_NAME>.fly.dev` (no scheme or port). The tagged release workflow
injects that hostname into the exported clients; never ship `FLY_API_TOKEN` in
a game build.
Godot's `ENetMultiplayerPeer.create_client()` accepts a fully qualified domain
name, so the client does not need to pin Fly's IPv4 address.

For a one-off local player export, set `network/public_server_host` in
`project.godot` to `YOUR_FLY_APP_NAME.fly.dev`. Normal release exports get the
same value from `TROOP_PUBLIC_SERVER_HOST`. `TROOP_SERVER_HOST` is an environment
override for development or managed launchers; the environment configured in
`fly.toml` exists only inside the server Machine and is not inherited by player
builds.

The main menu's **PLAY ONLINE** button uses this configured hostname and remains
disabled while it is empty. Raw host/join commands remain available only for
local diagnostics and explicitly addressed development sessions.

## Deploy and inspect

After the public client hostname and GitHub secrets are in place, push a server
change or start the workflow manually. Inspect the rollout with:

```bash
fly status --app YOUR_FLY_APP_NAME
fly services list --app YOUR_FLY_APP_NAME
fly logs --app YOUR_FLY_APP_NAME
```

Join from two separate Internet connections and verify movement, combat, chest
claims, disconnect handling, and voice traffic. Then repeat with at least three
clients: the old two-terminal host/join fixture cannot prove that client traffic
is relayed correctly between multiple non-server peers.

The server is configured as one always-on Machine with automatic crash restarts.
That keeps one authoritative match coherent, but it intentionally has no
Machine-level failover: a host failure or deploy disconnects the current match.
For a public launch, deploy versioned client/server protocol pairs and reject
incompatible clients with a clear update-required message. Before adding a
second region or Machine, implement shared matchmaking/session routing so every
client in one match is sent to the same authority.

## Local image build

With Docker installed, build the same image GitHub/Fly will build:

```bash
docker build --tag troop-server:local .
```

The build downloads Godot 4.7 and its matching export templates from the
official `godotengine/godot-builds` release, runs the project's smoke fixture,
exports the `Linux Server` preset, and boot-checks the exported executable. The
runtime image runs as the unprivileged `troop` user.

A successful image build proves the project parses, emits its smoke sentinel,
exports the dedicated binary, and starts that binary headlessly. The external
Internet join still needs a deployed Fly app, dedicated IPv4 allocation, GitHub
secrets, and the public client hostname described above.

## Admin access

Grant yourself (and only yourself) in-game admin by setting a shared secret on
the server — `fly secrets set TROOP_ADMIN_TOKEN=<long-random-string>` — and
launching your own client with `TROOP_ADMIN_KEY=<the-same-string>`. The server
compares the two during registration; display names are never trusted. Kick
and temp-ban verbs act on connected peers, and address bans persist in the
machine's `user://bans.json`.
