#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
stop_bg api
# Deleting a namespace removes its interfaces, the veth peers and any qdiscs on them.
netns_del lab-net-cli lab-net-rtr lab-net-srv
exit 0
