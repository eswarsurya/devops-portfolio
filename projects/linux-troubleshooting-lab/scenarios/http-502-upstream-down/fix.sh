#!/usr/bin/env bash
# Bring the upstream back. nginx needs no change: it retries the upstream on
# the next request.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

start_bg upstream python3 "$LAB_DIR/lib/httpd.py" --bind 127.0.0.1 --port 19001 --name orders-api
wait_until 10 port_open "" 19001
ss -ltnp 'sport = :19001'
