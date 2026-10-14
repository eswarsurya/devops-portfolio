#!/usr/bin/env bash
# Healthy = curl verifies the certificate against the CA, and the served
# certificate is valid for at least 30 more days.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
curl -sS --max-time 5 --cacert "$STATE/ca/ca.pem" \
  --resolve api.lab.internal:18443:127.0.0.1 https://api.lab.internal:18443/
openssl s_client -connect 127.0.0.1:18443 -servername api.lab.internal < /dev/null 2>/dev/null \
  | openssl x509 -noout -enddate -checkend $(( 30 * 86400 ))
