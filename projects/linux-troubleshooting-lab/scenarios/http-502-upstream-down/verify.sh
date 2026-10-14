#!/usr/bin/env bash
# Healthy = the proxy returns 200 with the upstream's body.
set -euo pipefail
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:18080/)"
echo "HTTP $code"
[[ "$code" == "200" ]]
curl -sS --max-time 5 http://127.0.0.1:18080/
