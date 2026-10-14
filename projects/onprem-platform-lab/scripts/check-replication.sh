#!/usr/bin/env bash
# Replication health check, run by Rundeck every minute (and by hand).
# For each replica: IO thread running, SQL thread running, and lag under the threshold.
# Exit 0 = all healthy, 2 = at least one replica is broken or lagging.
# If ES_URL is set, every result is also indexed into Elasticsearch (index: replication-health).
set -uo pipefail

HOSTS=${REPLICA_HOSTS:-"db1 db2 db3"}
MAX_LAG=${MAX_LAG_SECONDS:-30}
: "${MYSQL_MONITOR_PASSWORD:?set MYSQL_MONITOR_PASSWORD}"
status=0

for host in $HOSTS; do
  if ! out=$(MYSQL_PWD="$MYSQL_MONITOR_PASSWORD" mysql -h "$host" -umonitor --connect-timeout=5 -e "SHOW REPLICA STATUS\G" 2>&1); then
    io="unreachable"; sqlt="unreachable"; lag="null"; err=$(echo "$out" | tail -1)
  else
    field() { echo "$out" | sed -n "s/^ *$1: //p" | head -1; }
    io=$(field Replica_IO_Running); sqlt=$(field Replica_SQL_Running)
    lag=$(field Seconds_Behind_Source); err=$(field Last_SQL_Error)
    [ -z "$lag" ] || [ "$lag" = "NULL" ] && lag="null"
  fi

  state="OK"
  if [ "$io" != "Yes" ] || [ "$sqlt" != "Yes" ]; then state="CRITICAL"
  elif [ "$lag" = "null" ] || [ "$lag" -gt "$MAX_LAG" ]; then state="CRITICAL"; fi
  [ "$state" = "OK" ] || status=2

  echo "$state $host io=$io sql=$sqlt lag=${lag}s${err:+ error=\"$err\"}"

  if [ -n "${ES_URL:-}" ]; then
    doc=$(printf '{"@timestamp":"%s","host":"%s","state":"%s","io_running":"%s","sql_running":"%s","lag_seconds":%s}' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$host" "$state" "$io" "$sqlt" "$lag")
    curl -s -o /dev/null -XPOST "$ES_URL/replication-health/_doc" -H 'Content-Type: application/json' -d "$doc" || true
  fi
done

exit $status
