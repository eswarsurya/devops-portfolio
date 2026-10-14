#!/usr/bin/env bash
# "ps shows a pile of <defunct> processes." Who owns them, and why are they not going away?
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

step "1. Find zombies (STAT starting with Z, shown as <defunct>)"
show_sh "ps -eo pid,ppid,stat,etime,comm,args | awk 'NR==1 || \$3 ~ /^Z/'"
echo "top shows the same count in its header line:"
show_sh "top -b -n 1 | sed -n '2p'"

step "2. Who is the parent? Group zombies by PPID"
show_sh "ps -eo ppid=,stat= | awk '\$2 ~ /^Z/ {print \$1}' | sort | uniq -c | sort -rn"
ppid="$(ps -eo ppid=,stat= | awk '$2 ~ /^Z/ {print $1}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
count="$(ps -eo ppid=,stat= | awk -v p="$ppid" '$1 == p && $2 ~ /^Z/' | wc -l)"
echo "Parent with the most zombies: pid $ppid ($count zombies)"

step "3. What is the parent doing?"
show ps -o pid,ppid,stat,etime,comm,args -p "$ppid"
show_sh "grep -E '^(Name|State|SigIgn|SigCgt)' /proc/$ppid/status"
sigcgt="$(awk '/^SigCgt/ {print $2}' "/proc/$ppid/status")"
# SIGCHLD is signal 17, so bit 16 of the mask.
if (( (16#$sigcgt >> 16) & 1 )); then
  echo "SigCgt has bit 17 (SIGCHLD) set: the parent has a handler."
else
  echo "SigCgt does not include SIGCHLD (signal 17): the parent has no handler for finished children,"
  echo "and it is not calling wait() either, or the zombies would be gone."
fi
unit="$(ps -o unit= -p "$ppid" | awk '{print $1}')"
echo "systemd unit that owns the parent: $unit"

step "4. Does kill -9 on a zombie help? Try it on one"
zpid="$(ps -eo pid=,ppid=,stat= | awk -v p="$ppid" '$2 == p && $3 ~ /^Z/ {print $1; exit}')"
show kill -9 "$zpid"
sleep 0.5
if [[ -d "/proc/$zpid" ]] && grep -q '^State:.*Z' "/proc/$zpid/status"; then
  show_sh "grep '^State' /proc/$zpid/status"
  echo "Still a zombie. It has already exited: there is nothing left to kill. Only its exit status"
  echo "sits in the process table, waiting for the parent to collect it with wait()."
  kill9=no
else
  kill9=yes
fi

finding parent_pid "$ppid"
finding parent_comm "$(cat "/proc/$ppid/comm")"
finding zombie_count "$count"
finding unit "$unit"
finding kill9_removes_zombie "$kill9"
