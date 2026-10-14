#!/usr/bin/env bash
# nginx on 127.0.0.1:18080 proxies to the orders-api upstream on 127.0.0.1:19001.
# The break: the upstream process dies (killed with SIGKILL, like a crash).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

mkdir -p "$STATE/nginx/tmp" "$STATE/nginx/logs"
chmod 777 "$STATE/nginx/tmp"
cat > "$STATE/nginx/nginx.conf" <<EOF
worker_processes 1;
daemon off;
pid $STATE/nginx/nginx.pid;
error_log $STATE/nginx/logs/error.log warn;
events { worker_connections 64; }
http {
  access_log $STATE/nginx/logs/access.log;
  client_body_temp_path $STATE/nginx/tmp/body;
  proxy_temp_path $STATE/nginx/tmp/proxy;
  fastcgi_temp_path $STATE/nginx/tmp/fastcgi;
  uwsgi_temp_path $STATE/nginx/tmp/uwsgi;
  scgi_temp_path $STATE/nginx/tmp/scgi;
  upstream orders_api { server 127.0.0.1:19001; }
  server {
    listen 127.0.0.1:18080;
    location / { proxy_pass http://orders_api; }
  }
}
EOF
nginx -t -e "$STATE/nginx/logs/error.log" -c "$STATE/nginx/nginx.conf"

start_bg upstream python3 "$LAB_DIR/lib/httpd.py" --bind 127.0.0.1 --port 19001 --name orders-api
start_bg nginx nginx -e "$STATE/nginx/logs/error.log" -c "$STATE/nginx/nginx.conf"
wait_until 10 port_open "" 19001
wait_until 10 port_open "" 18080
echo "before the crash: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/)"

kill -KILL "$(cat "$STATE/upstream.pid")"
rm -f "$STATE/upstream.pid"
echo "orders-api killed"

plant http_status 502
plant upstream 127.0.0.1:19001
plant upstream_error connection_refused
plant upstream_listening no
