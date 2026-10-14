#!/usr/bin/env bash
# Remove the leftover maintenance rules (in real life: through the config
# management that owns the firewall, so they do not come back).
set -euo pipefail
ip netns exec lab-fw-srv nft delete table inet maintenance
echo "Removed table inet maintenance. Ruleset now:"
ip netns exec lab-fw-srv nft list ruleset
