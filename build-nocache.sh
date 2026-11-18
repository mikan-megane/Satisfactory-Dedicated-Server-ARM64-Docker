#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Full rebuild without any Docker layer cache.
exec docker compose build --no-cache "$@"
