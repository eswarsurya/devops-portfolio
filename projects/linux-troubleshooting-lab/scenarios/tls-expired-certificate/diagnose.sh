#!/usr/bin/env bash
# "Every client of payments-api fails with an SSL error since this morning."
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
CAFILE="$STATE/ca/ca.pem"
URL="https://api.lab.internal:18443/"
RESOLVE="api.lab.internal:18443:127.0.0.1"

step "1. What does the client see? (curl -v shows the TLS handshake)"
show curl -v --max-time 5 --cacert "$CAFILE" --resolve "$RESOLVE" "$URL"
rc=0; curl -s -o /dev/null --max-time 5 --cacert "$CAFILE" --resolve "$RESOLVE" "$URL" || rc=$?
echo "curl exit $rc. 60 = the peer certificate could not be verified. 7 or 28 would be a network problem."

step "2. Look at the handshake and the verify result with openssl s_client"
s_client() {
  openssl s_client -connect 127.0.0.1:18443 -servername api.lab.internal \
    -CAfile "$CAFILE" -verify_hostname api.lab.internal "$@" < /dev/null 2>&1
}
echo "$ openssl s_client -connect 127.0.0.1:18443 -servername api.lab.internal -CAfile ca.pem -verify_hostname api.lab.internal"
s_client > "$STATE/s_client.txt"
grep -E 'depth=|verify error|Verify return code|subject=|issuer=|Protocol|Cipher is' "$STATE/s_client.txt"
code="$(sed -nE 's/.*Verify return code: ([0-9]+).*/\1/p' "$STATE/s_client.txt" | tail -1)"
echo "Verify return code $code. 10 = certificate has expired, 62 = hostname mismatch, 20/21 = unknown issuer."

step "3. Decode the certificate the server actually sends"
s_client -showcerts | openssl x509 -noout -subject -issuer -dates -ext subjectAltName > "$STATE/cert.txt" 2>&1
show cat "$STATE/cert.txt"
not_after="$(sed -nE 's/^notAfter=(.*)$/\1/p' "$STATE/cert.txt")"
echo "Today is $(date -u '+%b %e %H:%M:%S %Y GMT'). The certificate stopped being valid on $not_after."
show_sh "openssl s_client -connect 127.0.0.1:18443 -servername api.lab.internal </dev/null 2>/dev/null | openssl x509 -noout -checkend 0"

step "4. Rule out the other usual suspects: is the name right?"
if grep -q 'DNS:api.lab.internal' "$STATE/cert.txt"; then
  hostname_matches=yes
  echo "SAN includes DNS:api.lab.internal, so the name is fine. Only the dates are wrong."
else
  hostname_matches=no
  echo "SAN does not include api.lab.internal."
fi

finding curl_exit "$rc"
finding verify_code "$code"
finding not_after "$not_after"
finding hostname_matches "$hostname_matches"
