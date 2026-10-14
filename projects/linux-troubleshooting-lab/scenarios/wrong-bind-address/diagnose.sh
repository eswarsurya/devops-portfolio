#!/usr/bin/env bash
# "inventory-api is up (the health check on the box passes) but clients get connection refused."
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

step "1. From the client: what exactly fails?"
show ip netns exec lab-bind-cli curl -sS --max-time 5 http://10.202.0.1:8080/
rc=0; ip netns exec lab-bind-cli curl -s -o /dev/null --max-time 5 http://10.202.0.1:8080/ || rc=$?
case "$rc" in
  7) client_error=connection_refused ;;
  28) client_error=timeout ;;
  0) client_error=none ;;
  *) client_error="curl_exit_$rc" ;;
esac
echo "curl exit $rc = $client_error. Refused comes back at once: the host answered with a TCP RST,"
echo "so the network path is fine and nothing is listening on that address and port."

step "2. Is the host up at all?"
show ip netns exec lab-bind-cli ping -c 2 -W 1 10.202.0.1
host_reachable=no
ip netns exec lab-bind-cli ping -c 1 -W 1 10.202.0.1 >/dev/null 2>&1 && host_reachable=yes

step "3. On the server: what is listening, on which address, which process?"
show ip netns exec lab-bind-srv ss -ltnp
line="$(ip netns exec lab-bind-srv ss -Hltnp 'sport = :8080' | head -1)"
listen_addr="$(awk '{print $4}' <<<"$line")"
comm="$(grep -oE 'users:\(\("[^"]+"' <<<"$line" | cut -d'"' -f2)"
echo "Listening on $listen_addr ($comm). 127.0.0.1 is the loopback address: only local clients can connect."

step "4. Confirm: works locally, fails remotely"
show ip netns exec lab-bind-srv curl -sS --max-time 5 http://127.0.0.1:8080/
show ip netns exec lab-bind-srv curl -sS --max-time 5 http://10.202.0.1:8080/

finding listen_addr "$listen_addr"
finding listener_comm "$comm"
finding client_error "$client_error"
finding host_reachable "$host_reachable"
