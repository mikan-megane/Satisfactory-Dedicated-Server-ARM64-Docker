#!/bin/bash
#
# Docker healthcheck.
#
# The game binary runs inside FEX, so the process name shown by ps is "exe" but
# the full command line still contains FactoryServer-Linux-Shipping. During a
# map load the HTTPS API is unavailable, so checking the process is more
# reliable than probing port 7777.
#
set -euo pipefail

pgrep -f 'FactoryServer-Linux-Shipping' >/dev/null 2>&1
