#!/usr/bin/env bash
# Healthy = no single process uses more than 80% of a CPU over a 2-second sample.
set -euo pipefail
export LC_ALL=C
read -r cpu pid comm < <(top -b -n 2 -d 2 -w 200 \
  | awk '/^top -/{n++} n==2 && $1 ~ /^[0-9]+$/ {print $9, $1, $12}' | sort -rn | head -1)
echo "Busiest process: $comm (pid $pid) at ${cpu}% CPU"
awk -v c="$cpu" 'BEGIN { exit !(c < 80) }'
