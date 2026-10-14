#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
stop_bg api
stop_bg dnsmasq
netns_del lab-dns-cli lab-dns-srv
rm -rf /etc/netns/lab-dns-cli
exit 0
