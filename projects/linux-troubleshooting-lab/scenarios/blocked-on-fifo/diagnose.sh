#!/usr/bin/env bash
# "The job consumer is up but has processed nothing. No errors, no CPU." What is it waiting for?
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

pid="$(pgrep -x job-consumer | head -1)"

step "1. Process state: running, sleeping, or stuck in the kernel?"
show ps -o pid,stat,wchan:32,pcpu,etime,comm -p "$pid"
show_sh "grep -E '^(State|voluntary_ctxt_switches)' /proc/$pid/status"
show cat "/proc/$pid/wchan"; echo
echo "S = interruptible sleep (waiting for an event). D would be uninterruptible, usually disk or NFS I/O."
echo "wchan is the kernel function it sleeps in. A pipe function here means it waits on a pipe."

step "2. Kernel stack (root only)"
show cat "/proc/$pid/stack"

step "3. Which system call is it blocked in? Attach strace for 3 seconds"
timeout 3 strace -p "$pid" > "$STATE/strace.txt" 2>&1
echo "$ timeout 3 strace -p $pid"
cat "$STATE/strace.txt"
syscall="$(grep -oE '^(read|openat|futex|wait4|poll|epoll_wait|select|accept4?|recvfrom)\(' "$STATE/strace.txt" | head -1 | tr -d '(')"
fdnum="$(grep -oE "^${syscall}\(([0-9]+)" "$STATE/strace.txt" | head -1 | grep -oE '[0-9]+$')"
echo "Blocked in $syscall() on file descriptor $fdnum, with no return value: the call never finished."

step "4. What is file descriptor $fdnum?"
show ls -l "/proc/$pid/fd/$fdnum"
target="$(readlink "/proc/$pid/fd/$fdnum")"
show_sh "stat -c '%n is a %F' $target"

step "5. Who holds the other end of the pipe?"
show lsof -nP "$target"
writer=""
for f in /proc/[0-9]*/fd/*; do
  [[ "$(readlink "$f" 2>/dev/null)" == "$target" ]] || continue
  p="$(cut -d/ -f3 <<<"$f")"
  flags="$(awk '/^flags:/ {print $2}' "/proc/$p/fdinfo/$(basename "$f")" 2>/dev/null)"
  # Access mode is the lowest two bits of flags (octal): 1 = O_WRONLY.
  if [[ -n "$flags" && $(( 8#$flags & 3 )) -eq 1 ]]; then writer="$p"; fi
done
echo "Writer: pid $writer ($(cat "/proc/$writer/comm"))"
show ps -o pid,stat,wchan:32,etime,comm -p "$writer"
timeout 2 strace -p "$writer" > "$STATE/strace-writer.txt" 2>&1
echo "$ timeout 2 strace -p $writer"
cat "$STATE/strace-writer.txt"
echo "The writer keeps the pipe open (so the reader gets no EOF) but sleeps instead of writing."
echo "The consumer is fine. The producer is the problem."

finding blocked_comm "$(cat "/proc/$pid/comm")"
finding blocked_syscall "$syscall"
finding blocked_on "$target"
finding writer_pid "$writer"
finding writer_comm "$(cat "/proc/$writer/comm")"
