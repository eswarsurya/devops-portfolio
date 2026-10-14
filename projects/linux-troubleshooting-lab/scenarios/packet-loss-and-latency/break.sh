#!/usr/bin/env bash
# Three namespaces, a client and a server with a router between them:
#   lab-net-cli 10.204.1.10 <--> [10.204.1.1 lab-net-rtr 10.204.2.1] <--> 10.204.2.10 lab-net-srv
# The break: the router's link towards the client goes bad. tc netem adds 40 ms
# of delay and drops 5% of packets leaving veth-rtr-cli.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

for ns in lab-net-cli lab-net-rtr lab-net-srv; do
  ip netns add "$ns"
  ip -n "$ns" link set lo up
done
ip link add veth-net-cli type veth peer name veth-rtr-cli
ip link add veth-net-srv type veth peer name veth-rtr-srv
ip link set veth-net-cli netns lab-net-cli
ip link set veth-rtr-cli netns lab-net-rtr
ip link set veth-rtr-srv netns lab-net-rtr
ip link set veth-net-srv netns lab-net-srv
ip -n lab-net-cli addr add 10.204.1.10/24 dev veth-net-cli
ip -n lab-net-rtr addr add 10.204.1.1/24 dev veth-rtr-cli
ip -n lab-net-rtr addr add 10.204.2.1/24 dev veth-rtr-srv
ip -n lab-net-srv addr add 10.204.2.10/24 dev veth-net-srv
ip -n lab-net-cli link set veth-net-cli up
ip -n lab-net-rtr link set veth-rtr-cli up
ip -n lab-net-rtr link set veth-rtr-srv up
ip -n lab-net-srv link set veth-net-srv up
ip -n lab-net-cli route add default via 10.204.1.1
ip -n lab-net-srv route add default via 10.204.2.1
ip netns exec lab-net-rtr sysctl -qw net.ipv4.ip_forward=1

start_bg api ip netns exec lab-net-srv python3 "$LAB_DIR/lib/httpd.py" --port 8080 --name files-api
wait_until 10 port_open lab-net-srv 8080
ip netns exec lab-net-cli curl -sS --max-time 5 http://10.204.2.10:8080/

ip netns exec lab-net-rtr tc qdisc add dev veth-rtr-cli root netem delay 40ms loss 5%
ip netns exec lab-net-rtr tc qdisc show dev veth-rtr-cli

plant lossy_ns lab-net-rtr
plant lossy_iface veth-rtr-cli
plant netem_delay 40ms
plant netem_loss 5%
plant kernel_retransmissions yes
plant tshark_retransmissions yes
