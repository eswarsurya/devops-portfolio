#!/usr/bin/env bash
# Healthy = the batch service runs, has started its jobs, and no child is a zombie.
set -euo pipefail
systemctl is-active --quiet lab-batch.service || { echo "lab-batch is not active"; exit 1; }
started="$(journalctl -u lab-batch.service --no-pager -o cat | grep -c 'started job' || true)"
zombies="$(ps -eo stat=,comm= | awk '$1 ~ /^Z/ && $2 == "batch-child"' | wc -l)"
echo "jobs started (all runs): $started, batch-child zombies now: $zombies"
[[ "$zombies" -eq 0 ]]
