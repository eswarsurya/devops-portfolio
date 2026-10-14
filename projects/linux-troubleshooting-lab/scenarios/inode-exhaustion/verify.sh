#!/usr/bin/env bash
# Healthy = a new upload can be written and inode use is under 90%.
set -euo pipefail
MNT=/srv/linux-lab-data
use="$(df --output=ipcent "$MNT" | tail -1 | tr -dc '0-9')"
echo "inode use: ${use}%"
echo "test upload" > "$MNT/app/uploads/verify-upload" || { echo "write failed"; exit 1; }
rm -f "$MNT/app/uploads/verify-upload"
(( use < 90 ))
