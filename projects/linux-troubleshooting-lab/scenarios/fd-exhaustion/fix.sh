#!/usr/bin/env bash
# Deploy the version that closes the file, and restart. Raising the limit
# would only delay the same failure.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

sed -i 's/^mode=leak$/mode=fixed/' "$STATE/upload-api.conf"
systemctl restart lab-upload-api.service
sleep 3
pid="$(systemctl show -p MainPID --value lab-upload-api.service)"
echo "upload-api restarted as pid $pid with $(ls "/proc/$pid/fd" | wc -l) open descriptors"
