#!/usr/bin/env bash
# End-to-end checks for the running lab. Each check prints PASS or FAIL; the script exits non-zero on any FAIL.
# Run from the project folder after: render-config.sh, docker compose up -d, setup-replication.sh, rundeck.sh import
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
set -a; . ./.env; set +a

failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; echo "::error title=onprem-platform-lab::$1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
not() { ! "$@"; }
section() { echo; echo "== $1"; }

sql() { docker compose exec -T "$1" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N -e "$0"' "$2"; }
retry() { local n=$1; shift; for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 3; done; return 1; }
HOST=portal.dublin-dc.lab
https() { curl -sk --resolve "$HOST:8443:127.0.0.1" "$@"; }
code() { https -o /dev/null -w '%{http_code}' "$@"; }

# ------------------------------------------------------------------
section "MySQL replication"
sql db1 "CREATE DATABASE IF NOT EXISTS labcheck; CREATE TABLE IF NOT EXISTS labcheck.orders (id INT AUTO_INCREMENT PRIMARY KEY, written_on VARCHAR(8))"
retry 10 sql db2 "SELECT COUNT(*) FROM labcheck.orders" >/dev/null 2>&1   # wait for the table to replicate
sql db1 "INSERT INTO labcheck.orders (written_on) VALUES ('db1')"
sql db2 "INSERT INTO labcheck.orders (written_on) VALUES ('db2')"
rows_on() { [ "$(sql "$1" "SELECT COUNT(*) FROM labcheck.orders")" = "2" ]; }
check "write on db1 reaches db2 (master-master)" retry 10 rows_on db2
check "write on db2 reaches db1 (master-master)" retry 10 rows_on db1
check "both writes reach the read replica db3" retry 10 rows_on db3
ids=$(sql db1 "SELECT GROUP_CONCAT(id % 2 ORDER BY written_on) FROM labcheck.orders")
check "no id collisions: db1 hands out odd ids, db2 even ($ids)" test "$ids" = "1,0"
db3_write() { sql db3 "INSERT INTO labcheck.orders (written_on) VALUES ('db3')" >/dev/null 2>&1; }
check "db3 refuses direct writes, even from root (super_read_only)" not db3_write
health() { docker compose exec -T rundeck bash -c 'set -a; . /opt/lab/env/monitor.env; /opt/lab/check-replication.sh'; }
check "replication health check reports all replicas OK" health

# ------------------------------------------------------------------
section "TLS certificate from the ACME flow (Pebble)"
issuer=$(echo | openssl s_client -connect 127.0.0.1:8443 -servername "$HOST" 2>/dev/null | openssl x509 -noout -issuer)
echo "      $issuer"
check "Nginx serves a certificate issued over ACME by the Pebble CA" grep -q Pebble <<<"$issuer"
redirect=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H "Host: $HOST" http://127.0.0.1:8080/)
check "HTTP redirects to HTTPS ($redirect)" grep -q "^301 https://$HOST/" <<<"$redirect"
hsts() { [[ $(https -I "https://$HOST:8443/") == *[Ss]trict-[Tt]ransport-[Ss]ecurity* ]]; }
check "HSTS header is set" hsts

# ------------------------------------------------------------------
section "WordPress on Apache/PHP through the load balancer"
wp_ready() { [[ $(https "https://$HOST:8443/wp-admin/install.php") == *WordPress* ]]; }
check "WordPress installer loads (PHP connected to MySQL through db1)" retry 20 wp_ready || true
if ! wp_ready; then
  page=$(https -i "https://$HOST:8443/wp-admin/install.php" | head -c 1500 | tr -d '\r')
  echo "::warning title=WordPress response::$(echo "$page" | grep -vi '^<link\|^<meta' | head -14 | cut -c1-200 | sed ':a;N;$!ba;s/\n/%0A/g')"
fi

served_by() { https -o /dev/null -D - "https://$HOST:8443/ops/" | sed -n 's/^x-served-by: *//Ip' | tr -d '\r'; }
nodes=$(for _ in $(seq 1 12); do served_by; sleep 0.2; done | sort -u | tr '\n' ' ')
check "requests are spread over both web nodes ($nodes)" test "$nodes" = "web1 web2 "

# ------------------------------------------------------------------
section "LDAP authentication and administration"
check "ops page asks for a login" test "$(code "https://$HOST:8443/ops/")" = "401"
check "alice (in LDAP group sre) can open it" test "$(code -u "alice:$ALICE_PASSWORD" "https://$HOST:8443/ops/")" = "200"
check "bob (developers only) is refused" test "$(code -u "bob:$BOB_PASSWORD" "https://$HOST:8443/ops/")" = "401"
./scripts/ldap-admin.sh add-user carol "Carol Kelly" "carol-$RUNDECK_API_TOKEN" >/dev/null
check "new user carol is refused before joining sre" test "$(code -u "carol:carol-$RUNDECK_API_TOKEN" "https://$HOST:8443/ops/")" = "401"
./scripts/ldap-admin.sh add-to-group carol sre >/dev/null
check "carol gets access once added to sre" test "$(code -u "carol:carol-$RUNDECK_API_TOKEN" "https://$HOST:8443/ops/")" = "200"
./scripts/ldap-admin.sh remove-from-group carol sre >/dev/null
check "carol loses access when removed from sre" test "$(code -u "carol:carol-$RUNDECK_API_TOKEN" "https://$HOST:8443/ops/")" = "401"

# ------------------------------------------------------------------
section "Nginx resilience"
sleep 2   # let the rate-limit bucket refill
statuses=$(seq 1 80 | xargs -P 40 -I{} curl -sk --resolve "$HOST:8443:127.0.0.1" -o /dev/null -w '%{http_code}\n' "https://$HOST:8443/ops/" | sort | uniq -c | tr '\n' ' ')
echo "      burst of 80 requests: $statuses"
check "rate limiting answers a burst with 429s" grep -q " 429" <<<"$statuses"
sleep 3
docker compose stop web1 >/dev/null 2>&1
only_web2() {
  local seen; seen=$(for _ in $(seq 1 8); do served_by; sleep 0.2; done | sort -u | tr '\n' ' ')
  [ "$seen" = "web2 " ]
}
check "with web1 down, every request is served by web2" retry 5 only_web2
docker compose start web1 >/dev/null 2>&1

# ------------------------------------------------------------------
section "Site-to-site VPN (WireGuard)"
check "branch gateway reaches the data-centre end of the tunnel" docker compose exec -T branch-gw ping -c 3 -W 2 10.99.0.1
vpn_code=$(docker compose exec -T branch-gw curl -sk -o /dev/null -w '%{http_code}' --resolve "$HOST:443:172.30.10.200" "https://$HOST/ops/")
check "branch office reaches the portal inside the lab network through the tunnel ($vpn_code)" test "$vpn_code" = "401"
check "tunnel has a recent handshake" sh -c "docker compose exec -T dc-gw wg show wg0 latest-handshakes | awk '{exit !(\$2 > 0)}'"

# ------------------------------------------------------------------
section "Rundeck runbooks and replication alerting"
check "replication check job succeeds while replication is healthy" ./scripts/rundeck.sh run "Replication health check"
sql db3 "STOP REPLICA SQL_THREAD"
echo "      (stopped the SQL thread on db3 to simulate broken replication)"
check "replication check job fails when db3 stops applying changes" not env EXPECT_FAILURE=1 ./scripts/rundeck.sh run "Replication health check"
alerts() { docker compose exec -T alert-receiver wget -qO- http://127.0.0.1:9000/alerts; }
fired() { alerts | grep -q '"type": "alert".*replication-health'; }
check "an alert was sent to the alert receiver" retry 20 fired
if ! fired; then
  echo "::warning title=alert receiver contents::$(alerts | tail -5 | sed ':a;N;$!ba;s/\n/%0A/g')"
  echo "::warning title=rundeck notification log::$(docker compose logs --no-color rundeck 2>&1 | grep -i -E 'notif|webhook|url' | tail -10 | cut -c1-250 | sed ':a;N;$!ba;s/\n/%0A/g')"
fi
sql db3 "START REPLICA SQL_THREAD"
check "job succeeds again after replication is repaired" retry 5 ./scripts/rundeck.sh run "Replication health check"
# a recovery notice must come after the most recent alert (the scheduled job also sends them while healthy)
resolved() { alerts | python3 -c "
import json,sys
types=[json.loads(l)['type'] for l in sys.stdin if 'replication-health' in l]
sys.exit(0 if 'alert' in types and 'resolve' in types[len(types)-1-types[::-1].index('alert'):] else 1)"; }
check "a recovery notice followed" retry 20 resolved
check "LDAP access audit job runs" ./scripts/rundeck.sh run "SRE group membership audit"

# ------------------------------------------------------------------
section "ELK: logs, metrics and uptime"
es() { curl -fsS "http://localhost:9200/$1"; }
count() { es "$1/_count${2:+?q=$2}" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['count'])" 2>/dev/null || echo 0; }
has_docs() { [ "$(count "$@")" -gt 0 ]; }
check "Logstash shipped Nginx access logs (nginx-access-*)" retry 40 has_docs "nginx-access-*"
check "the 429s are tagged rate_limited in Elasticsearch" retry 10 has_docs "nginx-access-*" "tags:rate_limited"
check "Metricbeat is collecting MySQL metrics" retry 30 has_docs "metricbeat-*" "event.module:mysql"
check "Metricbeat is collecting Nginx metrics" retry 30 has_docs "metricbeat-*" "event.module:nginx"
check "replication check results are indexed (replication-health)" retry 10 has_docs "replication-health"
for monitor in portal-https mysql-db1 mysql-db2 mysql-db3 ldap kibana rundeck; do
  check "Heartbeat reports monitor '$monitor' up" retry 40 has_docs "heartbeat-*" "monitor.id:$monitor%20AND%20monitor.status:up"
done
kibana_ok() { curl -fsS http://localhost:5601/api/status | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin)['status']['overall']['level']=='available' else 1)"; }
check "Kibana is available" retry 40 kibana_ok

echo
if [ "$failures" -eq 0 ]; then echo "All checks passed."; else echo "$failures check(s) failed."; fi
exit "$failures"
