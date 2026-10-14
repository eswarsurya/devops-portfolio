#!/usr/bin/env bash
# Issue a new certificate from the same CA (90 days, same name) and restart
# the service so it loads it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
CA="$STATE/ca"

openssl req -new -newkey rsa:2048 -nodes -subj "/CN=api.lab.internal" \
  -addext "subjectAltName=DNS:api.lab.internal" \
  -keyout "$STATE/server-new.key" -out "$STATE/server-new.csr" 2>/dev/null
openssl ca -batch -config "$CA/ca.cnf" -in "$STATE/server-new.csr" -out "$STATE/server-new.pem" \
  -days 90 -notext 2>/dev/null
mv "$STATE/server-new.pem" "$STATE/server.pem"
mv "$STATE/server-new.key" "$STATE/server.key"
echo "New certificate:"
openssl x509 -in "$STATE/server.pem" -noout -subject -dates

stop_bg api
start_bg api python3 "$LAB_DIR/lib/httpd.py" --bind 127.0.0.1 --port 18443 --name payments-api \
  --tls-cert "$STATE/server.pem" --tls-key "$STATE/server.key"
wait_until 10 port_open "" 18443
