#!/bin/bash
# Sourced by the official MySQL entrypoint on first start of each node.
# sql_log_bin=0 keeps these local: each node creates its own users, nothing is replicated.
docker_process_sql <<SQL
SET SESSION sql_log_bin = 0;
CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '${MYSQL_REPL_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY '${MYSQL_MONITOR_PASSWORD}';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'monitor'@'%';
SQL
