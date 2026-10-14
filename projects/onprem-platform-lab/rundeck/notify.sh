#!/bin/bash
# Sends an alert or a recovery notice to the on-call receiver (stands in for a pager such as PagerDuty).
#   notify.sh alert|resolve <job>
set -euo pipefail
type=$1 job=$2
curl -fsS -X POST "http://alert-receiver:9000/${type}?source=rundeck&job=${job}" \
  -H 'Content-Type: application/json' -d "{\"job\":\"${job}\",\"host\":\"$(hostname)\"}"
echo "sent ${type} for ${job}"
