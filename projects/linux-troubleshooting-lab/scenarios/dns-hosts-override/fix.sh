#!/usr/bin/env bash
# Remove the stale override so the name resolves through DNS again.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
cp /etc/netns/lab-dns-cli/hosts "$STATE/hosts.before-fix"
sed -i '/api\.lab\.internal/d' /etc/netns/lab-dns-cli/hosts
echo "Removed the api.lab.internal line from the client's /etc/hosts (old copy in $STATE/hosts.before-fix)."
ip netns exec lab-dns-cli getent hosts api.lab.internal
