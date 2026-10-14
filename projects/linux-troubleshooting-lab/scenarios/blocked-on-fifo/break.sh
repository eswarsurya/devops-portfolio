#!/usr/bin/env bash
# The consumer hangs: the producer opened the pipe but never writes to it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

FIFO="$STATE/jobs.fifo"
mkfifo "$FIFO"
: > "$STATE/consumer.status"
start_bg consumer python3 "$HERE/jobs.py" consumer "$FIFO" "$STATE/consumer.status"
wait_until 5 grep -q 'waiting for jobs' "$STATE/consumer.status"
start_bg producer python3 "$HERE/jobs.py" producer "$FIFO" "$STATE/consumer.status" --stuck
sleep 2

plant blocked_comm job-consumer
plant blocked_syscall read
plant blocked_on "$FIFO"
plant writer_pid "$(cat "$STATE/producer.pid")"
plant writer_comm job-producer
