#!/usr/bin/env bash
#   lab-fw-cli 10.203.0.10  <-- veth -->  lab-fw-srv 10.203.0.1
#                                           orders-api  :8080
#                                           billing-api :8081
# The break: leftover firewall rules on the server. Port 8080 is silently
# DROPPED; port 8081 is REJECTED with a TCP reset. Both apps are healthy.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

netns_pair lab-fw-cli lab-fw-srv veth-fw-cli veth-fw-srv 10.203.0.10 10.203.0.1
start_bg orders ip netns exec lab-fw-srv python3 "$LAB_DIR/lib/httpd.py" --port 8080 --name orders-api
start_bg billing ip netns exec lab-fw-srv python3 "$LAB_DIR/lib/httpd.py" --port 8081 --name billing-api
wait_until 10 port_open lab-fw-srv 8080
wait_until 10 port_open lab-fw-srv 8081

# nftables in the server's namespace only; the runner's own firewall is untouched.
ip netns exec lab-fw-srv nft -f - <<'EOF'
table inet maintenance {
  chain input {
    type filter hook input priority 0; policy accept;
    tcp dport 8080 counter drop
    tcp dport 8081 counter reject with tcp reset
  }
}
EOF
ip netns exec lab-fw-srv nft list ruleset

plant port_8080 timeout
plant port_8081 refused
plant drop_rule_port 8080
plant reject_rule_port 8081
plant synack_from_8080 no
plant rst_from_8081 yes
