# Runaway CPU process

**Reported symptom:** "The box is slow. Load is up and the fans would be screaming if it had fans."

## What `break.sh` does

Compiles [spin.c](spin.c) and starts it as `report-worker` with two worker threads that spin in a busy loop (`for (;;) n++;`) instead of waiting for work. The main thread sleeps in `pause()`.

## Investigate

1. **Is the CPU really busy?** `vmstat 1 3`. Read from the second line. High `us` (user) with low `wa` means real computation, not waiting for disk.
2. **Which process?** `top -b -n 2 -d 1 -o %CPU` and use the second sample (the first is an average since the process started). `pidstat -u 1 1` gives the same per process. In CI:
   ```
       PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
      2780 root      20   0   19084   1812   1700 S 199.0   0.0   0:17.02 report-worker
   ```
   199% means about two full CPUs. Above 100% is normal for a multi-threaded process.
3. **What is it?** `ps -o pid,ppid,stat,nlwp,etime,args -p PID` and `ls -l /proc/PID/exe`. `NLWP` is the thread count.
4. **Which threads?** `ps -L -p PID`, `top -H -p PID` or `pidstat -t -p PID 1 1`. In CI two threads sat at 100% each and the main thread at 0%:
   ```
       PID     LWP STAT %CPU COMMAND
      2780    2780 Ssl   0.0 report-worker
      2780    2782 Rsl   100 report-worker
      2780    2783 Rsl   100 report-worker
   ```
5. **User space or kernel?** `/proc/PID/task/TID/stat` fields 14 and 15 are user and system time in clock ticks. CI showed `utime=1081 stime=0`: the thread never makes a system call. `/proc/PID/task/TID/status` showed `voluntary_ctxt_switches: 0`: it never waits for anything, it only gets preempted.

On a real service the next step is *where* in the code: `perf top -p PID` or `perf record -g -p PID`, or a language profiler (py-spy, async-profiler, `jstack` for Java thread dumps).

## Root cause

A bug in the worker loop: it polls in a tight loop instead of blocking on a queue, a condition variable or a socket.

## Fix

`fix.sh` sends SIGTERM (SIGKILL only if the process ignores it for 5 seconds). That stops the bleeding. The lasting fix is in the code: block on the work source, or at least sleep between polls.

## Prevention

- Alert on per-process CPU, not only host CPU.
- Put services in a cgroup with `CPUQuota=` so one bad process cannot starve the box.
- Keep `perf` and a profiler available on hosts so you can see *where* the time goes during the incident.

## What CI checks

The fault is real (the busiest process is above 80% of a CPU), `diagnose.sh` reports the planted PID, the process name and the number of busy threads (2), and after the fix no process uses more than 80% of a CPU.

## Interview questions this covers

- **Load average is 8 on a 4-CPU box. Is that bad?** It depends on why. Load counts runnable tasks *and* tasks in uninterruptible sleep (`D`). Check `vmstat` `r` against the CPU count and look for `D` states and `wa` before saying "CPU bound".
- **How do you find the hot thread in a Java process?** `top -H -p PID` for the busy thread id, convert it to hex, find that `nid=0x...` in a `jstack` dump.
- **`%CPU` shows 200%. How?** top counts per CPU by default (Irix mode). 100% is one full CPU. Press `I` to switch to Solaris mode (divided by CPU count).
- **What is the difference between SIGTERM and SIGKILL?** SIGTERM can be caught, so the process can clean up. SIGKILL cannot be caught or ignored; the kernel just ends the process.
- **User time vs system time?** User is your code. High system time points at syscalls, page faults or lock contention in the kernel.
