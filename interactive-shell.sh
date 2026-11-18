#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Open a root shell inside the running container.
exec docker compose exec satisfactory-server bash
