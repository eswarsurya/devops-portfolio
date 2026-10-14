#!/usr/bin/env bash
# A private CA and an HTTPS service for api.lab.internal on 127.0.0.1:18443.
# The break: the server certificate expired on 30 June 2024 and nobody renewed it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

CA="$STATE/ca"
mkdir -p "$CA/newcerts"
: > "$CA/index.txt"
echo 1000 > "$CA/serial"
cat > "$CA/ca.cnf" <<EOF
[ ca ]
default_ca = lab_ca
[ lab_ca ]
dir             = $CA
database        = \$dir/index.txt
new_certs_dir   = \$dir/newcerts
serial          = \$dir/serial
certificate     = \$dir/ca.pem
private_key     = \$dir/ca.key
default_md      = sha256
policy          = policy_any
copy_extensions = copy
unique_subject  = no
[ policy_any ]
commonName = supplied
EOF

# The lab's root CA (valid for 10 years from today).
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Lab Internal Root CA" \
  -keyout "$CA/ca.key" -out "$CA/ca.pem" 2>/dev/null

# The server certificate: right name, wrong dates.
openssl req -new -newkey rsa:2048 -nodes -subj "/CN=api.lab.internal" \
  -addext "subjectAltName=DNS:api.lab.internal" \
  -keyout "$STATE/server.key" -out "$STATE/server.csr" 2>/dev/null
openssl ca -batch -config "$CA/ca.cnf" -in "$STATE/server.csr" -out "$STATE/server.pem" \
  -startdate 20240101000000Z -enddate 20240630000000Z -notext 2>/dev/null
openssl x509 -in "$STATE/server.pem" -noout -subject -dates

start_bg api python3 "$LAB_DIR/lib/httpd.py" --bind 127.0.0.1 --port 18443 --name payments-api \
  --tls-cert "$STATE/server.pem" --tls-key "$STATE/server.key"
wait_until 10 port_open "" 18443

plant curl_exit 60
plant verify_code 10
plant not_after "Jun 30 00:00:00 2024 GMT"
plant hostname_matches yes
