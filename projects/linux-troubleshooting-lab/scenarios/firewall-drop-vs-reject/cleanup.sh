#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
stop_bg orders
stop_bg billing
# Deleting the namespace also deletes its nftables ruleset.
netns_del lab-fw-cli lab-fw-srv
exit 0
