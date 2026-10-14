#!/usr/bin/env bash
# Two hosts in network namespaces:
#   lab-dns-cli 10.201.0.10  <-- veth -->  lab-dns-srv 10.201.0.1 (DNS, dnsmasq)
#                                                       10.201.0.2 (api.lab.internal:8080)
# DNS is correct. The break: a stale /etc/hosts line on the client still points
# api.lab.internal at the old server, 10.201.0.99, which no longer exists.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

netns_pair lab-dns-cli lab-dns-srv veth-dns-cli veth-dns-srv 10.201.0.10 10.201.0.1
ip -n lab-dns-srv addr add 10.201.0.2/24 dev veth-dns-srv

# The DNS server: answers api.lab.internal with the current address.
start_bg dnsmasq ip netns exec lab-dns-srv dnsmasq --keep-in-foreground --conf-file=/dev/null \
  --no-resolv --no-hosts --user=root --listen-address=10.201.0.1 --bind-interfaces \
  --address=/api.lab.internal/10.201.0.2 --log-queries --log-facility=-
# The application server.
start_bg api ip netns exec lab-dns-srv python3 "$LAB_DIR/lib/httpd.py" \
  --bind 10.201.0.2 --port 8080 --name orders-api
wait_until 10 port_open lab-dns-srv 8080
wait_until 10 bash -c "ip netns exec lab-dns-srv ss -Hlun | grep -q '10.201.0.1:53'"

# Client resolver config. `ip netns exec` bind-mounts files from /etc/netns/<ns>/
# over /etc inside the namespace, so the runner's own /etc is never touched.
mkdir -p /etc/netns/lab-dns-cli
echo "nameserver 10.201.0.1" > /etc/netns/lab-dns-cli/resolv.conf
echo "hosts: files dns" > /etc/netns/lab-dns-cli/nsswitch.conf
cat > /etc/netns/lab-dns-cli/hosts <<'EOF'
127.0.0.1   localhost
# added during the 2023 migration, never removed
10.201.0.99 api.lab.internal
EOF

plant getent_ip 10.201.0.99
plant dns_ip 10.201.0.2
plant cause hosts_file_override
plant stale_line "10.201.0.99 api.lab.internal"
