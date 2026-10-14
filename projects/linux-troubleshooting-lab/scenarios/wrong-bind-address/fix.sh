#!/usr/bin/env bash
# Listen on all addresses (or the specific service address), then restart.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

echo "BIND_ADDRESS=0.0.0.0" > "$STATE/inventory-api.env"
# shellcheck disable=SC1091
source "$STATE/inventory-api.env"
stop_bg api
start_bg api ip netns exec lab-bind-srv python3 "$LAB_DIR/lib/httpd.py" \
  --bind "$BIND_ADDRESS" --port 8080 --name inventory-api
wait_until 10 port_open lab-bind-srv 8080
ip netns exec lab-bind-srv ss -ltnp 'sport = :8080'
