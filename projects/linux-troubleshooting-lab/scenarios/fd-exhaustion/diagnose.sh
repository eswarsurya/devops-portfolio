#!/usr/bin/env bash
# "Uploads fail with 'Too many open files'." Which process, which limit, which file?
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

step "1. The error in the application log"
show_sh "tail -n 3 $STATE/upload-api.log"
echo "'[Errno 24] Too many open files' is EMFILE: this process hit its own limit (RLIMIT_NOFILE)."
echo "ENFILE (errno 23) would mean the whole system ran out (fs.file-max)."
errno=""
grep -q 'Errno 24' "$STATE/upload-api.log" && errno=EMFILE

step "2. Which process? Rank processes by how close they are to their own open-files limit"
echo "$ for each /proc/<pid>: count fds in /proc/<pid>/fd, read 'Max open files' from /proc/<pid>/limits"
for p in /proc/[0-9]*; do
  n="$(ls "$p/fd" 2>/dev/null | wc -l)"
  lim="$(awk '/^Max open files/ {print $4}' "$p/limits" 2>/dev/null)"
  [[ -n "$lim" && "$lim" =~ ^[0-9]+$ && "$n" -gt 0 ]] || continue
  echo "$(( n * 100 / lim )) $n $lim ${p#/proc/} $(cat "$p/comm" 2>/dev/null)"
done | sort -rn | head -5 > "$STATE/fd-rank.txt"
printf '%-5s %-6s %-7s %-7s %s\n' "USE%" "OPEN" "LIMIT" "PID" "COMMAND"
while read -r pct n lim p c; do printf '%-5s %-6s %-7s %-7s %s\n' "$pct%" "$n" "$lim" "$p" "$c"; done < "$STATE/fd-rank.txt"
pid="$(awk 'NR==1 {print $4}' "$STATE/fd-rank.txt")"
echo "Closest to its limit: pid $pid ($(cat "/proc/$pid/comm")). Raw counts mislead: a busy process with a high limit can hold more fds and be fine."

step "3. Its limit and how many it has open"
show_sh "grep -E 'Limit|open files' /proc/$pid/limits"
limit="$(awk '/^Max open files/ {print $4}' "/proc/$pid/limits")"
open="$(ls "/proc/$pid/fd" | wc -l)"
echo "open descriptors: $open, soft limit: $limit"
show prlimit --pid "$pid" --nofile
show systemctl show lab-upload-api.service -p LimitNOFILE
show_sh "cat /proc/sys/fs/file-nr   # system-wide: allocated, unused, max"

step "4. What are the descriptors pointing at?"
show_sh "ls -l /proc/$pid/fd 2>/dev/null | head -8"
show_sh "lsof -nP -p $pid | awk 'NR>1 {print \$NF}' | sort | uniq -c | sort -rn | head -5"
leaked="$(lsof -nP -p "$pid" -F n 2>/dev/null | sed -n 's/^n//p' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
leaked_count="$(lsof -nP -p "$pid" -F n 2>/dev/null | grep -cxF "n$leaked")"
echo "The same file is open $leaked_count times: $leaked"
echo "One file open over and over = an open() without a close() in a loop or per request."

finding pid "$pid"
finding fd_limit "$limit"
finding leaked_file "$leaked"
finding errno "$errno"
