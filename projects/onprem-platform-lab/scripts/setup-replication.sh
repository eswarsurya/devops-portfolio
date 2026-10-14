#!/usr/bin/env bash
# Wires up replication once the three MySQL nodes are running:
#   db1 <-> db2  master-master (each replicates from the other)
#   db1  -> db3  read replica
# Then creates the WordPress database on db1, so it reaches every node through replication.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }

sql() { # sql <node> <statement>
  docker compose exec -T "$1" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N -e "$0"' "$2"
}

for node in db1 db2 db3; do
  for _ in $(seq 1 60); do
    sql "$node" "SELECT 1" >/dev/null 2>&1 && break
    sleep 2
  done
  if ! sql "$node" "SELECT 1" >/dev/null; then
    echo "diagnostics for $node:"
    docker compose exec -T "$node" sh -c 'echo "root pw length: ${#MYSQL_ROOT_PASSWORD}"; mysql --version;
      mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "SELECT CONCAT(\"-p works as \", CURRENT_USER())" 2>&1 | tail -1;
      MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -h127.0.0.1 -N -e "SELECT \"tcp+MYSQL_PWD works\"" 2>&1 | tail -1;
      ls /docker-entrypoint-initdb.d' || true
    exit 1
  fi
  # start every node from an empty GTID history so auto-positioning lines up
  sql "$node" "RESET BINARY LOGS AND GTIDS"
done

point_at() { # point_at <replica> <source>
  sql "$1" "CHANGE REPLICATION SOURCE TO SOURCE_HOST='$2', SOURCE_USER='repl', \
SOURCE_PASSWORD='${MYSQL_REPL_PASSWORD}', SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1; START REPLICA;"
}
point_at db2 db1
point_at db1 db2
point_at db3 db1
# db3 is a read replica: nothing but replication may write to it (persists across restarts)
sql db3 "SET PERSIST super_read_only = ON"

sql db1 "CREATE DATABASE IF NOT EXISTS wordpress; \
CREATE USER IF NOT EXISTS 'wordpress'@'%' IDENTIFIED BY '${WORDPRESS_DB_PASSWORD}'; \
GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'%';"

for node in db1 db2 db3; do
  for _ in $(seq 1 30); do
    running=$(sql "$node" "SELECT COUNT(*) FROM performance_schema.replication_applier_status WHERE SERVICE_STATE='ON'")
    [ "$running" = "1" ] && break
    sleep 2
  done
  echo "$node: replica applier running"
done
