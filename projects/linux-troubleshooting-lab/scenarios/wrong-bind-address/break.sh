#!/usr/bin/env bash
#   lab-bind-cli 10.202.0.10  <-- veth -->  lab-bind-srv 10.202.0.1 (inventory-api :8080)
# The break: the service is configured to listen on 127.0.0.1 only, so it works
# from the server itself but nobody else can reach it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

netns_pair lab-bind-cli lab-bind-srv veth-bind-cli veth-bind-srv 10.202.0.10 10.202.0.1

echo "BIND_ADDRESS=127.0.0.1" > "$STATE/inventory-api.env"
# shellcheck disable=SC1091
source "$STATE/inventory-api.env"
start_bg api ip netns exec lab-bind-srv python3 "$LAB_DIR/lib/httpd.py" \
  --bind "$BIND_ADDRESS" --port 8080 --name inventory-api
wait_until 10 port_open lab-bind-srv 8080

plant listen_addr 127.0.0.1:8080
plant listener_comm inventory-api
plant client_error connection_refused
plant host_reachable yes
