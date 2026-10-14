#!/usr/bin/env bash
# "The site returns 502 Bad Gateway." Is it nginx, or what sits behind it?
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
LOGS="$STATE/nginx/logs"

step "1. The response, with headers"
show curl -si --max-time 5 http://127.0.0.1:18080/orders
status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:18080/orders)"
echo "HTTP $status from 'Server: nginx'. The proxy answered, so nginx itself is up."
echo "502 = nginx could not get a valid response from the upstream. 504 would be: the upstream was too slow."

step "2. nginx's error log says why"
show tail -n 3 "$LOGS/error.log"
line="$(grep 'while connecting to upstream' "$LOGS/error.log" | tail -1)"
upstream="$(sed -nE 's#.*upstream: "http://([^/"]+)/?.*#\1#p' <<<"$line")"
case "$line" in
  *"(111: Connection refused)"*) upstream_error=connection_refused ;;
  *"timed out"*) upstream_error=timeout ;;
  *) upstream_error=other ;;
esac
echo "Upstream $upstream: $upstream_error (errno 111 = ECONNREFUSED: nothing listens on that port)."
show tail -n 3 "$LOGS/access.log"

step "3. Where does nginx send traffic? (the config, not what we assume)"
show nginx -T -e "$LOGS/error.log" -c "$STATE/nginx/nginx.conf"

step "4. Is anything listening on the upstream port?"
port="${upstream##*:}"
show ss -ltnp "( sport = :18080 or sport = :$port )"
if port_open "" "$port"; then upstream_listening=yes; else upstream_listening=no; fi
echo "Port $port listening: $upstream_listening"
show_sh "pgrep -a -x orders-api || echo 'no orders-api process'"
show curl -sS --max-time 3 "http://$upstream/"
echo "The upstream is down. Next: restart it, then find out why it died (its logs, dmesg for OOM, exit code)."

finding http_status "$status"
finding upstream "$upstream"
finding upstream_error "$upstream_error"
finding upstream_listening "$upstream_listening"
