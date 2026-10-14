#!/usr/bin/env bash
# Run a service with a file descriptor leak under a 128 open-files limit.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

mkdir -p "$STATE/data"
printf 'sku,price\nA-100,9.99\n' > "$STATE/data/prices.csv"
cat > "$STATE/upload-api.conf" <<EOF
mode=leak
data=$STATE/data/prices.csv
log=$STATE/upload-api.log
EOF

systemd-run --unit=lab-upload-api --property=LimitNOFILE=128 \
  python3 "$HERE/upload_api.py" "$STATE/upload-api.conf"

wait_until 30 grep -q 'Too many open files' "$STATE/upload-api.log"
echo "upload-api is now failing with EMFILE"

plant pid "$(systemctl show -p MainPID --value lab-upload-api.service)"
plant fd_limit 128
plant leaked_file "$STATE/data/prices.csv"
plant errno EMFILE
