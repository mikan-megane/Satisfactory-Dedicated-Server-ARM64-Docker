# Satisfactory Dedicated Server for ARM64 (Docker)

> 🇯🇵 Japanese README: [readme.ja.md](readme.ja.md)

Run the official Satisfactory dedicated server on an ARM64 machine
(Oracle Cloud Ampere, AWS Graviton, Raspberry Pi 5, …) with Docker.

The Linux server binary is **x86-64 only**, so it runs through
[FEX-Emu](https://github.com/FEX-Emu/FEX). No privileged container, no
`binfmt_misc` registration, no QEMU.

> **ARM64 only.** Build the image on the same class of ARM64 machine that will
> run it. Building on x86-64 is not supported.

---

## Status: the client-join crash

The old version of this project pinned a 2024 FEX commit and hit a crash when a
client joined (the "conveyor belt crash"). That was an emulator bug: FEX fixed
its float→integer overflow behaviour in
[FEX-2501](https://github.com/FEX-Emu/FEX/releases/tag/FEX-2501), which
explicitly lists *"Satisfactory's server crashing"* as fixed.
Satisfactory 1.2.2 also fixed a game-side crash when clients join late-game
sessions.

This image therefore does **not** build FEX from an old commit. It installs the
current official FEX package (2611.1 at the time of writing) from the
`ppa:fex-emu/fex` PPA, together with the current stable server (1.2.5).

Verified in this repository's test environment (Ubuntu 24.04 ARM64, 4 vCPU,
23 GB RAM):

- clean image build and fresh SteamCMD install,
- new world creation through the HTTPS API,
- map load (~40 s under emulation) and normal simulation ticks,
- autosave, clean shutdown (world saved), and restart from the saved world,
- no crash during several minutes of idle simulation.

A real game client was not available in the test environment, but the FEX and
game bugs that caused the old client-join crash are both fixed upstream.

---

## Requirements

| Item | Minimum | Recommended |
| --- | --- | --- |
| CPU | ARMv8.0-A, 4 vCPU | 8 vCPU, high single-core performance |
| RAM | 8 GB | 16 GB for large saves / 4+ players |
| Disk | ~8 GB free | 15 GB+ (saves and backups grow) |
| Kernel | Linux 5.15+ | current distro kernel |
| Docker | 24+ with Compose v2 | current Docker Engine |
| OS | Ubuntu 22.04/24.04 ARM64, Debian ARM64 | Ubuntu 24.04 ARM64 |

The server is heavily single-thread bound. Emulation costs roughly 2–4× the CPU
time of native x86-64, so do not expect a 2 vCPU free-tier VM to be enough for a
large factory.

---

## Quick start

```bash
git clone https://github.com/mikan-megane/Satisfactory-Dedicated-Server-ARM64-Docker.git
cd Satisfactory-Dedicated-Server-ARM64-Docker

cp .env.example .env
# Make PUID/PGID match the user that owns the data directories:
sed -i "s/^PUID=.*/PUID=$(id -u)/; s/^PGID=.*/PGID=$(id -g)/" .env

docker compose up -d --build
docker compose logs -f
```

The first start downloads:

1. the FEX x86-64 rootfs (~500 MB compressed, ~1.9 GB extracted, into
   `./fex-data`),
2. the Satisfactory dedicated server (~2.9 GB, into `./satisfactory`).

This usually takes 5–15 minutes depending on the network. SteamCMD sometimes
fails once with `Failed to install app '1690800' (Missing configuration)` right
after its own self-update; the entrypoint retries automatically, so this message
followed by a successful update is normal. Later starts reuse both downloads and
only check the Steam build ID.

The container is healthy when the log contains a line like:

```
LogNet: Name:GameNetDriver ... IpNetDriver listening on port 7777
```

and `docker compose ps` shows `(healthy)`.

### Ports

| Port | Protocol | Purpose |
| --- | --- | --- |
| 7777 | TCP | HTTPS Server API + game traffic |
| 7777 | UDP | Game traffic + lightweight query |
| 8888 | TCP | Reliable messaging (required since Update 1.1) |

Open **all three** in the host firewall and, on Oracle Cloud, in the VCN
security list. Docker publishes ports directly, so `ufw` rules do not apply to
published container ports.

If you change `SERVER_GAME_PORT` or `SERVER_MESSAGING_PORT`, the image publishes
them 1:1 and passes `-Port` / `-ReliablePort` to the server automatically (this
was verified with 7778/8889). Do not use asymmetric mappings such as
`17777:7777`; the server advertises its internal port to clients.

Changing `SERVER_GAME_PORT` also changes the settings file the server uses
(`ServerSettings.<port>.sav`), so it comes up as a new, unclaimed server without
an auto-load session. Claim it again and load your save once. Leave the game port
at 7777 unless you really need to change it.

---

## First connection

1. Start Satisfactory and open **Server Manager**.
2. Add a server with `<public-ip>:7777`.
3. Claim it by setting the admin password.

The server is unclaimed on first start, so you can also claim it headlessly:

```bash
# 1) Get an InitialAdmin token (only works while the server is unclaimed)
curl -sk -X POST https://YOUR_IP:7777/api/v1 \
  -H 'Content-Type: application/json' \
  -d '{"function":"PasswordlessLogin","data":{"MinimumPrivilegeLevel":"InitialAdmin"}}'

# 2) Claim the server with the returned token
curl -sk -X POST https://YOUR_IP:7777/api/v1 \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer PASTE_TOKEN_HERE' \
  -d '{"function":"ClaimServer","data":{"ServerName":"My Factory","AdminPassword":"change-me"}}'
```

---

## Configuration

Copy `.env.example` to `.env` and edit it. Compose reads `.env` automatically.

| Variable | Default | Description |
| --- | --- | --- |
| `PUID` / `PGID` | `1000` | Owner of `./satisfactory`, `./config`, `./fex-data`. Set to `id -u` / `id -g` on the host. |
| `FEX_ARCH` | `auto` | FEX build: `auto`, `armv8.0`, `armv8.2`, `armv8.4`. `auto` uses the build machine's CPU. |
| `SERVER_GAME_PORT` | `7777` | Game/API port (TCP+UDP), passed as `-Port`. |
| `SERVER_MESSAGING_PORT` | `8888` | Reliable messaging port (TCP), passed as `-ReliablePort`. |
| `ALWAYS_UPDATE_ON_START` | `true` | Check the Steam build ID on every start and update only when it changed. |
| `EXPERIMENTAL_BRANCH` | `false` | Install the `experimental` Steam branch. |
| `EXTRA_PARAMS` | empty | Extra arguments for `FactoryServer.sh`. Empty uses `-log -unattended -ini:Engine:[HTTPServer.Listeners]:DefaultBindAddress=any`. |

Useful `EXTRA_PARAMS` (append to the default rather than replacing it if you
still want unattended logging):

```
-log -unattended -multihome=0.0.0.0
```

`-multihome` is only needed on hosts with multiple public interfaces. The
container already binds to all interfaces.

### FEX CPU selection

The image can only contain one FEX build. `FEX_ARCH=auto` inspects
`/proc/cpuinfo` **at build time**:

| CPU | Package |
| --- | --- |
| ARMv8.4+ (Graviton 3/4, Neoverse V2) | `fex-emu-armv8.4` |
| ARMv8.2+ (Ampere Altra, Graviton 2, Neoverse N1) | `fex-emu-armv8.2` |
| ARMv8.0/8.1 (Raspberry Pi 4/5, older SoCs) | `fex-emu-armv8.0` |

If you build on one machine and run on another with fewer CPU features, set
`FEX_ARCH` explicitly to the oldest machine's level. An image built for a newer
level will die with `Illegal instruction` on older CPUs.

---

## Data and backups

| Path | Contents |
| --- | --- |
| `./config/FactoryGame/Saved/SaveGames/server/` | Session saves, including the `shutdown` save |
| `./config/FactoryGame/Saved/SaveGames_backup/` | Automatic save backups |
| `./config/FactoryGame/Saved/SaveGames/ServerSettings.7777.sav` | Server name, passwords, API certificate |
| `./satisfactory/FactoryGame/Saved/Config/LinuxServer/` | `Engine.ini`, `GameUserSettings.ini` |
| `./satisfactory/FactoryGame/Saved/Logs/FactoryGame.log` | Full game log |
| `./fex-data/` | FEX rootfs and code cache (safe to delete; it re-downloads) |

Back up `./config` and `./satisfactory/FactoryGame/Saved/Config` regularly.
The game files themselves can always be re-downloaded by SteamCMD.

### Migrating an existing world

1. Stop the server.
2. Copy the `.sav` file into `./config/FactoryGame/Saved/SaveGames/server/`.
3. Start the server.
4. In Server Manager, load that save once, or set the auto-load session name.

The `shutdown` save is created automatically on a clean stop, so a restart
resumes from the last clean shutdown. It is overwritten on every stop; only the
five newest `shutdown-*.sav` backup copies are kept.

---

## Updating

With `ALWAYS_UPDATE_ON_START=true`, a container restart checks
`api.steamcmd.net` for the current build ID and runs SteamCMD only when the
installed build differs:

```bash
docker compose restart
docker compose logs -f
```

To update manually:

```bash
docker compose down
docker compose up -d
```

`docker compose down` stops the server through the graceful-shutdown path
below. Rebuilding the image (`docker compose build`) is only needed when this
repository's Dockerfile/scripts change, not for game updates.

For the experimental branch set `EXPERIMENTAL_BRANCH=true` and restart.

---

## Stopping safely

`docker compose down` / `docker compose stop` sends SIGTERM. The entrypoint then:

1. calls the local HTTPS API `SaveGame` with the save name `shutdown`,
2. calls `Shutdown` and waits up to 60 seconds for the game to exit,
3. falls back to SIGTERM if the API is unreachable.

`stop_grace_period` is 120 seconds. Do **not** use `docker kill` unless the
server is already hung; it skips the save.

The API call is unauthenticated only on the container's loopback interface
(`FG.DedicatedServer.AllowInsecureLocalAccess=1`). Requests from outside the
container still require authentication.

To reach the Unreal console, attach to the container:

```bash
docker attach satisfactory-server
# detach with Ctrl-P Ctrl-Q
```

---

## Performance notes

- **Single-core speed matters more than core count.** FEX emulation makes this
  even more important.
- 4 vCPU / 8 GB is enough for a small factory and 1–2 players. Late-game saves
  with many belts, trains and pipes benefit from 8 vCPU / 16 GB.
- A fresh world used ~3 GB RSS and ~90–100% of one vCPU while idle in testing
  (full 30 ticks/s on a 4 vCPU Ampere core).
- The entrypoint writes a tuned FEX configuration into `./fex-data` on first
  start:
  - `DisableL2Cache=false`, `DynamicL1Cache=false` — keep the full in-memory
    JIT caches alive (defaults trade stutter for RAM).
  - `DisableTelemetry=true`.
  Note that FEX's on-disk JIT cache (`DiskCache` option) needs the
  `FEXOfflineCompiler` tool, which the upstream PPA packages currently do not
  ship, so translated code is not cached across restarts. World load takes
  roughly one minute under emulation on a 4 vCPU machine regardless of warm-up.
- Keep the `./fex-data` volume: it holds the FEX rootfs and configuration.
- Raising `FG.AutosaveInterval` (default 300 s) in the client's Server Manager
  reduces the periodic autosave hitch on large saves; this image sets it to
  600 s on start only if you accept the tradeoff — a crash then loses up to
  10 minutes of progress (clean stops always save).
- Do not run the container with CPU limits that are too low; the UE server
  spawns worker threads and can stall if throttled.

---

## Troubleshooting

### `Invalid or Unsupported elf file` / `RootFS path doesn't exist`

The FEX rootfs is missing or the `./fex-data` volume was mounted empty.

```bash
docker compose down
rm -rf ./fex-data
docker compose up -d
```

It will be downloaded again on the next start.

### `Permission denied` for `/satisfactory` or `./config`

`PUID`/`PGID` do not match the host user. Set them to `id -u` / `id -g`, then:

```bash
docker compose down
sudo chown -R "$(id -u):$(id -g)" satisfactory config fex-data
docker compose up -d
```

### Clients cannot join

- Publish **7777/TCP**, **7777/UDP** and **8888/TCP**. Missing 8888 is the most
  common cause since Update 1.1.
- Open the same ports in the cloud provider's security list.
- Confirm the log says `IpNetDriver listening on port 7777`.
- If you changed ports, publish them 1:1 and let the entrypoint pass `-Port` /
  `-ReliablePort`.
- The first connection may take a while; the client downloads the world from
  the server.

### The server exits or restarts in a loop

```bash
docker compose logs --tail=200
tail -n 200 satisfactory/FactoryGame/Saved/Logs/FactoryGame.log
```

Common causes are a corrupt save (restore a backup), a full disk (`df -h`), or
the OOM killer on a small VM (`dmesg | tail`).

### `Illegal instruction`

The image was built with a higher `FEX_ARCH` than the CPU supports. Rebuild with
`FEX_ARCH=armv8.0` (or run on a newer ARM64 CPU).

### Healthcheck is unhealthy during startup

World loading under emulation can take a minute or more. The healthcheck has a
15-minute `start_period`; first-time installation can exceed it on slow
networks. Check `docker compose logs` rather than relying only on health status.

---

## How it works

```
Docker (Ubuntu 24.04 ARM64)
├── FEX-Emu (official PPA)          x86-64 → ARM64 translation
├── x86-64 FEX rootfs              ~/.fex/fex-emu/RootFS/Ubuntu_24_04
├── SteamCMD (x86)                 installs app 1690800 into /satisfactory
└── FactoryServer.sh (x86-64)      executed through FEXBash
```

- FEX is installed from the PPA instead of being compiled, which makes builds
  fast and avoids the build breakage that older versions of this project hit.
- The rootfs is downloaded with `FEXRootFSFetcher` into a volume and extracted,
  so the container does not need `/dev/fuse` or `--privileged`.
- SteamCMD is invoked with `+@sSteamCmdForcePlatformType linux` because recent
  SteamCMD versions otherwise mis-detect the host platform under emulation.
- Updates are skipped when the local `appmanifest_1690800.acf` build ID already
  matches Steam, avoiding a 3 GB validate on every restart.

---

## Credits

- Original ARM64 Docker project:
  [sa-shiro/Satisfactory-Dedicated-Server-ARM64-Docker](https://github.com/sa-shiro/Satisfactory-Dedicated-Server-ARM64-Docker)
- [FEX-Emu](https://github.com/FEX-Emu/FEX)
- [Satisfactory dedicated server documentation](https://satisfactory.wiki.gg/wiki/Dedicated_servers)

License: MIT (see [license.md](license.md)).
