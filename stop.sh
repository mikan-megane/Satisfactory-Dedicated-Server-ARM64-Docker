#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Stop the server. Docker sends SIGTERM and waits up to the configured
# stop_grace_period (120s) so the game can save before exiting.
exec docker compose down "$@"
