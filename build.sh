#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Build the ARM64 image. Run this on the ARM64 machine that will host the
# server; cross-building from x86-64 is not supported.
exec docker compose build "$@"
