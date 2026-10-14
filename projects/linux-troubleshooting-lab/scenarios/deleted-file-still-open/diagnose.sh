#!/usr/bin/env bash
# "The disk is full, but du says the files are small." Where did the space go?
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
MNT=/srv/linux-lab-logs

step "1. Compare what the filesystem says (df) with what the files add up to (du)"
show df -h "$MNT"
show du -sh "$MNT"
used_mb="$(df -BM --output=used "$MNT" | tail -1 | tr -dc '0-9')"
files_mb="$(du -sm "$MNT" | awk '{print $1}')"
echo "df used: ${used_mb} MiB, du total: ${files_mb} MiB, gap: $(( used_mb - files_mb )) MiB"
echo "A big gap means blocks still allocated to files that no directory points to:"
echo "deleted files that a process still holds open."

step "2. Find open files with a link count of 0 (deleted) on this filesystem"
show lsof -nP -a +L1 "$MNT"

step "3. The same, straight from /proc (works where lsof is not installed)"
pid=""; fd=""; path=""
for f in /proc/[0-9]*/fd/*; do
  target="$(readlink "$f" 2>/dev/null)" || continue
  if [[ "$target" == "$MNT/"*" (deleted)" ]]; then
    pid="$(cut -d/ -f3 <<<"$f")"
    fd="$(basename "$f")"
    path="${target% (deleted)}"
    break
  fi
done
show ls -l "/proc/$pid/fd/$fd"
show_sh "stat -L -c 'size=%s bytes, links=%h' /proc/$pid/fd/$fd"
show ps -o pid,etime,comm,args -p "$pid"
echo "pid $pid ($(cat "/proc/$pid/comm")) still writes to $path through fd $fd."

finding pid "$pid"
finding deleted_file "$path"
finding fd "$fd"
