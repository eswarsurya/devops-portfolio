#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
stop_bg nginx
stop_bg upstream
pkill -KILL -x orders-api 2>/dev/null || true
exit 0
