#!/usr/bin/env bash
# Who is using the CPU, and which threads inside it?
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
export LC_ALL=C

step "1. Is the CPU actually busy? (us = user time, sy = kernel, id = idle, wa = I/O wait)"
show vmstat 1 3
show uptime

step "2. Which process? top sorted by CPU, second sample so the numbers are current"
show_sh "top -b -n 2 -d 1 -o %CPU -w 200 | awk '/^top -/{n++} n==2' | head -15"

# Top consumer from a 1-second pidstat sample (current usage, not lifetime average).
pid="$(pidstat -u 1 1 | awk '/^Average:/ && $3 ~ /^[0-9]+$/ {print $8, $3}' | sort -rn | head -1 | awk '{print $2}')"
if [[ -z "$pid" ]]; then
  pid="$(ps -eo pid=,pcpu= --sort=-pcpu | head -1 | awk '{print $1}')"
fi
echo "Top CPU consumer: pid $pid"

step "3. What is it?"
show ps -o pid,ppid,user,stat,nlwp,pcpu,etime,comm,args -p "$pid"
show ls -l "/proc/$pid/exe"
show_sh "grep -E '^(Name|State|Threads|voluntary_ctxt_switches|nonvoluntary_ctxt_switches)' /proc/$pid/status"
echo "Note: /proc/<pid>/status counts context switches for the main thread only."

step "4. Which threads inside it? (ps -L prints one line per thread; LWP is the thread id)"
show ps -L -o pid,lwp,stat,pcpu,comm -p "$pid"
show_sh "top -H -b -n 1 -p $pid | tail -n +7"
show pidstat -t -p "$pid" 1 1

busy="$(ps -L -o pcpu= -p "$pid" | awk '$1 > 50 {n++} END {print n+0}')"
comm="$(cat "/proc/$pid/comm")"
echo "Threads above 50% CPU: $busy"

step "5. User space or kernel? Context switches of the busiest thread"
tid="$(ps -L -o lwp=,pcpu= -p "$pid" | sort -k2 -rn | head -1 | awk '{print $1}')"
show_sh "grep -E 'ctxt_switches' /proc/$pid/task/$tid/status"
show_sh "awk '{print \"utime(ticks)=\" \$14, \"stime(ticks)=\" \$15}' /proc/$pid/task/$tid/stat"
echo "utime grows while stime stays near zero: a pure user-space loop that never makes a syscall."
echo "Almost no voluntary switches: the thread never waits for anything, it only gets preempted."

finding pid "$pid"
finding comm "$comm"
finding busy_threads "$busy"
