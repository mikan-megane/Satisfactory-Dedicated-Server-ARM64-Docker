#!/bin/bash
#
# Entrypoint for the Satisfactory Dedicated Server on ARM64.
#
# Runs as root only to remap the steam user to PUID/PGID and fix ownership,
# then re-executes itself as steam. The x86-64 server itself is started through
# FEX-Emu (FEXBash).
#
set -Eeuo pipefail

SATISFACTORY_DIR="${SATISFACTORY_DIR:-/satisfactory}"
STEAMCMD_DIR="${STEAMCMD_DIR:-/home/steam/Steam}"
APP_ID="${APP_ID:-1690800}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
GAME_PORT="${GAME_PORT:-7777}"
MESSAGING_PORT="${MESSAGING_PORT:-8888}"
ALWAYS_UPDATE_ON_START="${ALWAYS_UPDATE_ON_START:-true}"
EXPERIMENTAL_BRANCH="${EXPERIMENTAL_BRANCH:-false}"
EXTRA_PARAMS="${EXTRA_PARAMS:--log -unattended -ini:Engine:[HTTPServer.Listeners]:DefaultBindAddress=any}"

export HOME="/home/steam"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.fex}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.fex}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.fex}"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

ROOTFS_DIR="$XDG_DATA_HOME/fex-emu/RootFS/Ubuntu_24_04"
ROOTFS_IMAGE="$XDG_DATA_HOME/fex-emu/RootFS/Ubuntu_24_04.sqsh"
FEX_CONFIG="$XDG_CONFIG_HOME/fex-emu/Config.json"

log() { printf '[init] %s\n' "$*"; }
warn() { printf '[init] WARNING: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Root phase: apply PUID/PGID, fix ownership, drop privileges
# ---------------------------------------------------------------------------
ensure_owner() {
  local dir="$1"
  [ -e "$dir" ] || return 0
  if [ "$(stat -c '%u' "$dir")" != "$PUID" ] || [ "$(stat -c '%g' "$dir")" != "$PGID" ]; then
    log "Fixing ownership of $dir (PUID=$PUID PGID=$PGID)..."
    chown -R "$PUID:$PGID" "$dir"
  fi
}

if [ "$(id -u)" -eq 0 ]; then
  log "Configuring steam user as UID=$PUID GID=$PGID"
  groupmod -o -g "$PGID" steam
  usermod -o -u "$PUID" steam

  mkdir -p "$XDG_DATA_HOME/fex-emu" "$XDG_CONFIG_HOME/fex-emu" \
           "$HOME/.steam/sdk64" "$HOME/.config/Epic" "$SATISFACTORY_DIR"

  ensure_owner "$XDG_DATA_HOME"
  ensure_owner "$XDG_CONFIG_HOME"
  ensure_owner "$HOME/.steam"
  ensure_owner "$HOME/.config"
  ensure_owner "$HOME/Steam"
  ensure_owner "$SATISFACTORY_DIR"

  exec gosu steam "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Steam phase
# ---------------------------------------------------------------------------

# FEX tuning applied on every start (see readme "Performance"):
#  - DisableL2Cache=false / DynamicL1Cache=false: keep the full in-memory JIT
#    caches alive (defaults trade stutter for RAM; servers have RAM to spare).
#  - DisableTelemetry: stop per-run telemetry writes.
#  Note: FEX's on-disk JIT cache (DiskCache option) needs FEXOfflineCompiler,
#  which the upstream PPA packages do not ship, so it is not enabled here.
setup_fex_config() {
  mkdir -p "$XDG_CONFIG_HOME/fex-emu"
  if [ -f "$FEX_CONFIG" ] && grep -q 'DisableL2Cache' "$FEX_CONFIG"; then
    return 0
  fi
  log "Writing tuned FEX configuration ($FEX_CONFIG)"
  printf '%s\n' '{
  "Config": {
    "RootFS": "Ubuntu_24_04",
    "DisableL2Cache": "false",
    "DynamicL1Cache": "false",
    "DisableTelemetry": "true"
  },
  "ThunksDB": {}
}' > "$FEX_CONFIG"
}

# FEX needs an x86-64 rootfs on ARM64 hosts. Download it once into the
# persistent .fex volume and extract it (avoids needing /dev/fuse in Docker).
setup_rootfs() {
  mkdir -p "$XDG_DATA_HOME/fex-emu/RootFS" "$XDG_CONFIG_HOME/fex-emu"

  # A valid extracted rootfs has a shell and os-release. Checking for these
  # catches a half-finished extraction (interrupted download, full disk).
  if [ -d "$ROOTFS_DIR" ] && [ -x "$ROOTFS_DIR/bin/sh" ] && [ -f "$ROOTFS_DIR/etc/os-release" ]; then
    rm -f "$ROOTFS_IMAGE"
    setup_fex_config
    return 0
  fi

  if [ -e "$ROOTFS_DIR" ]; then
    warn "Removing incomplete rootfs at $ROOTFS_DIR"
    rm -rf "$ROOTFS_DIR"
  fi
  rm -f "$ROOTFS_IMAGE" "$ROOTFS_IMAGE.part"

  log "FEX x86-64 rootfs not found. Downloading (~500 MB, first start only)..."
  local attempt
  for attempt in 1 2 3; do
    if command -v unbuffer >/dev/null 2>&1; then
      if unbuffer FEXRootFSFetcher -y -x; then
        break
      fi
    elif script -qec "FEXRootFSFetcher -y -x" /dev/null; then
      break
    fi
    warn "Rootfs download failed (attempt $attempt/3)"
    sleep 5
    if [ "$attempt" -eq 3 ]; then
      log "ERROR: could not install the FEX rootfs."
      exit 1
    fi
  done

  # Keep only the extracted rootfs; the .sqsh is no longer needed.
  rm -f "$ROOTFS_IMAGE"

  if [ ! -x "$ROOTFS_DIR/bin/sh" ]; then
    log "ERROR: FEXRootFSFetcher finished but $ROOTFS_DIR looks incomplete."
    exit 1
  fi

  # FEXRootFSFetcher writes its own Config.json; merge in our tuning on top.
  setup_fex_config
}

# Run SteamCMD (an x86 binary) through FEX. The ForcePlatformType flag is
# required on recent SteamCMD versions, otherwise it may pick the wrong depot.
steamcmd_run() {
  local args="$*"
  FEXBash -c "cd \"$STEAMCMD_DIR\" && ./steamcmd.sh $args"
}

setup_steamcmd() {
  mkdir -p "$HOME/.steam/sdk64"
  if [ -f "$STEAMCMD_DIR/linux64/steamclient.so" ]; then
    ln -sfn "$STEAMCMD_DIR/linux64/steamclient.so" "$HOME/.steam/sdk64/steamclient.so"
  fi

  log "Checking SteamCMD..."
  local attempt
  for attempt in 1 2 3; do
    if steamcmd_run "+quit"; then
      return 0
    fi
    warn "SteamCMD self-update failed (attempt $attempt/3)"
    sleep 5
  done
  warn "SteamCMD could not update itself. Continuing with the installed copy."
}

local_build_id() {
  sed -n 's/.*"buildid"[[:space:]]*"\([0-9][0-9]*\)".*/\1/p' \
    "$SATISFACTORY_DIR/steamapps/appmanifest_${APP_ID}.acf" 2>/dev/null | head -n 1
}

remote_build_id() {
  local branch="public"
  [ "$EXPERIMENTAL_BRANCH" = "true" ] && branch="experimental"

  curl -fsSL --max-time 15 "https://api.steamcmd.net/v1/info/$APP_ID" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)["data"]["1690800"]
    print(data["depots"]["branches"][sys.argv[1]]["buildid"])
except Exception:
    pass
' "$branch" 2>/dev/null || true
}

install_server() {
  local validate="${1:-validate}"
  local beta=""
  [ "$EXPERIMENTAL_BRANCH" = "true" ] && beta="-beta experimental"

  local attempt
  for attempt in 1 2 3; do
    log "Running SteamCMD app_update $APP_ID (attempt $attempt/3)..."
    if steamcmd_run "+@sSteamCmdForcePlatformType linux +@sSteamCmdForcePlatformBitness 64 +force_install_dir \"$SATISFACTORY_DIR\" +login anonymous +app_update $APP_ID $beta $validate +quit"; then
      return 0
    fi
    warn "SteamCMD update failed (attempt $attempt/3)"
    sleep 10
  done
  return 1
}

# Each clean stop creates a backup of the 'shutdown' save. Keep only the five
# newest ones so frequent restarts do not grow the config volume forever.
prune_shutdown_backups() {
  local dir="$HOME/.config/Epic/FactoryGame/Saved/SaveGames_backup"
  [ -d "$dir" ] || return 0

  find "$dir" -maxdepth 1 -type f -name 'shutdown-*.sav' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | tail -n +6 \
    | cut -d' ' -f2- \
    | while IFS= read -r file; do
        rm -f "$file"
      done
}

# ---------------------------------------------------------------------------
# Install / update
# ---------------------------------------------------------------------------
setup_rootfs
setup_steamcmd
prune_shutdown_backups

if [ ! -f "$SATISFACTORY_DIR/FactoryServer.sh" ]; then
  log "Satisfactory server is not installed yet."
  if ! install_server validate; then
    log "ERROR: installation failed. Check the network connection and retry."
    exit 1
  fi
elif [ "$ALWAYS_UPDATE_ON_START" = "true" ]; then
  local_id="$(local_build_id || true)"
  remote_id="$(remote_build_id || true)"

  if [ -n "$remote_id" ] && [ "$local_id" = "$remote_id" ]; then
    log "Server is up to date (build $local_id)."
  else
    log "Updating server (local=${local_id:-unknown} remote=${remote_id:-unknown})..."
    if ! install_server validate; then
      warn "Update failed. Starting the existing installation instead."
    fi
  fi
else
  log "Automatic update is disabled (ALWAYS_UPDATE_ON_START=false)."
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
cd "$SATISFACTORY_DIR"

# Allow the entrypoint to call the HTTPS API over loopback without a token.
# This is only reachable from inside the container (127.0.0.1); requests from
# outside still require authentication. It lets 'docker stop' save the world
# cleanly instead of killing the process mid-tick.
LOCAL_API_FLAG="-ini:Engine:[SystemSettings]:FG.DedicatedServer.AllowInsecureLocalAccess=1"
PORT_FLAGS="-Port=${GAME_PORT} -ReliablePort=${MESSAGING_PORT}"

SERVER_PID=""
SHUTTING_DOWN=0

shutdown_server() {
  [ "$SHUTTING_DOWN" -eq 1 ] && return 0
  SHUTTING_DOWN=1
  trap '' TERM INT

  log "Stop signal received. Saving the world before shutdown..."
  local api="https://127.0.0.1:${GAME_PORT}/api/v1"
  local api_ok=0

  # Save under a fixed name so the file is overwritten on every clean stop.
  if curl -skf --max-time 10 -X POST "$api" \
       -H 'Content-Type: application/json' \
       -d '{"function":"SaveGame","data":{"SaveName":"shutdown"}}' \
       >/dev/null 2>&1; then
    api_ok=1
  fi

  if curl -skf --max-time 10 -X POST "$api" \
       -H 'Content-Type: application/json' \
       -d '{"function":"Shutdown","data":{}}' \
       >/dev/null 2>&1; then
    api_ok=1
  fi

  if [ "$api_ok" -eq 0 ]; then
    warn "Server API is not reachable; stopping immediately."
    [ -n "$SERVER_PID" ] && kill -TERM "$SERVER_PID" 2>/dev/null || true
    return 0
  fi

  # Wait up to 60 seconds for FEX/game to exit on its own.
  local i
  for i in $(seq 1 60); do
    [ -n "$SERVER_PID" ] || return 0
    kill -0 "$SERVER_PID" 2>/dev/null || return 0
    sleep 1
  done

  warn "Server did not shut down in time; sending SIGTERM."
  if [ -n "$SERVER_PID" ]; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
  fi
}

log "Starting Satisfactory Dedicated Server..."
log "EXTRA_PARAMS: $EXTRA_PARAMS"
log "Passed arguments: $*"

FEXBash -c "cd \"$SATISFACTORY_DIR\" && ./FactoryServer.sh $EXTRA_PARAMS $PORT_FLAGS $LOCAL_API_FLAG $*" &
SERVER_PID=$!

trap shutdown_server TERM INT

set +e
wait "$SERVER_PID"
status=$?

# If the trap interrupted the first wait, reap the process once more.
if [ "$SHUTTING_DOWN" -eq 1 ]; then
  wait "$SERVER_PID" 2>/dev/null
  status=$?
fi

exit "$status"
