# Process hung on a blocking system call

**Reported symptom:** "The job consumer is running but has processed nothing for an hour. No errors in its log, no CPU use."

## What `break.sh` does

Creates a named pipe (FIFO), starts a consumer (`job-consumer`) that reads jobs from it, then starts a producer (`job-producer`) that opens the pipe for writing and hangs before writing anything, the way a producer stuck on a lock or a slow upstream would. See [jobs.py](jobs.py).

## Investigate

1. **What state is it in?** `ps -o pid,stat,wchan:32,pcpu,etime,comm -p PID`. In CI:
   ```
       PID STAT WCHAN                            %CPU     ELAPSED COMMAND
      3235 Ss   anon_pipe_read                    0.4       00:02 job-consumer
   ```
   `S` is interruptible sleep: waiting for an event. `wchan` is the kernel function it sleeps in. A process stuck in `D` (uninterruptible sleep) would point at disk or NFS instead, and would not even respond to SIGKILL until the I/O completes.
2. **Kernel stack.** `cat /proc/PID/stack` (root only). CI showed `anon_pipe_read` → `fifo_pipe_read` → `vfs_read` → `ksys_read`: a `read()` on a FIFO.
3. **Which system call, on which file?** `strace -p PID` attaches to the running process. CI printed `read(3, ` with no return value: blocked in `read()` on descriptor 3, and the call never finished.
4. **What is descriptor 3?** `ls -l /proc/PID/fd/3` points at `.../jobs.fifo`, and `stat -c %F` says it is a `fifo`.
5. **Who is on the other end?** `lsof -nP <fifo>`:
   ```
   COMMAND    PID USER   FD   TYPE DEVICE SIZE/OFF    NODE NAME
   job-consu 3235 root    3r  FIFO    8,1      0t0 9175048 /tmp/linux-lab/state/blocked-on-fifo/jobs.fifo
   job-produ 3239 root    3w  FIFO    8,1      0t0 9175048 /tmp/linux-lab/state/blocked-on-fifo/jobs.fifo
   ```
   (`r` = open for reading, `w` = for writing. Without lsof, `/proc/PID/fdinfo/N` has the open flags.) `strace -p` on the writer shows it sitting in `clock_nanosleep`. It holds the pipe open, so the reader never gets end-of-file, but it never writes.

## Root cause

The consumer is healthy. The producer is stuck, and because it keeps the write end open the consumer waits forever.

## Fix

`fix.sh` stops the stuck producer (the consumer then sees end-of-file and reopens the pipe) and starts a healthy producer, which writes three jobs. All three are processed.

## Prevention

- Timeouts on every blocking call (read, connect, lock) and a health check that tests progress ("processed a job in the last N minutes"), not just "the process exists".
- Alert on queue age or lag, not only on errors. This failure produces no errors at all.

## What CI checks

After `break.sh`, no job is processed. `diagnose.sh` reports the blocked process, the system call (`read`), the FIFO path, and the writer's PID and name, all found with `ps`/`/proc`/`strace`/`lsof`. After the fix, the consumer is alive and has processed jobs.

## Interview questions this covers

- **A process is "hung". What do you look at first?** Its state (`ps` STAT, `/proc/PID/status`), `wchan`, `/proc/PID/stack`, then `strace -p` to see the system call it is in.
- **What is the difference between `S` and `D` state?** `S` can be woken by signals. `D` is uninterruptible, usually waiting on disk or network storage, and counts towards load average.
- **Why can't you kill a process in `D` state?** The signal is only delivered when the kernel call returns. Fix the storage, or wait for its timeout.
- **What does `strace` cost?** It stops the process at every system call, which can slow it a lot. Use it briefly in production, or prefer `perf trace` / eBPF tools.
- **How do you find who holds the other end of a pipe or socket?** `lsof` on the path, or match the inode number (`pipe:[12345]`, `socket:[...]`) across `/proc/*/fd`.
