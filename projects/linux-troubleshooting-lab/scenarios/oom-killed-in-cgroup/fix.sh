#!/usr/bin/env bash
# Fix the leak (bound the cache), not the limit. Then restart the service.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

printf 'mode=bounded\nmax_mb=16\n' > "$STATE/cache.conf"
echo "Cache is now bounded to 16 MiB. The 64 MiB limit stays as a safety net."
systemctl restart lab-cache.service
sleep 1
systemctl status lab-cache.service --no-pager --lines=0 || true
