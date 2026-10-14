#!/usr/bin/env bash
# Remove the impairment. On a real network this is the "replace the bad cable /
# optic / NIC, or fail over to the other link" step.
set -euo pipefail
ip netns exec lab-net-rtr tc qdisc del dev veth-rtr-cli root
echo "Removed netem from lab-net-rtr/veth-rtr-cli:"
ip netns exec lab-net-rtr tc qdisc show dev veth-rtr-cli
