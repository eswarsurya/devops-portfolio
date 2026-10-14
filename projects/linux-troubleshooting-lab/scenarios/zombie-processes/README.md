# Zombie processes

**Reported symptom:** "`ps` shows a growing list of `<defunct>` processes. I ran `kill -9` on them and nothing happened."

## What `break.sh` does

Runs [batch_parent.py](batch_parent.py) as the systemd service `lab-batch.service`. It forks a child (`batch-child`) per job. Each child exits at once, but the parent never calls `wait()`, so every finished child stays in the process table as a zombie. It plants 8.

## Investigate

1. **Find them.** `ps -eo pid,ppid,stat,etime,comm,args | awk 'NR==1 || $3 ~ /^Z/'`. State `Z`, shown as `[batch-child] <defunct>`. `top` counts them in its header: `Tasks: 177 total, 1 running, 168 sleeping, 0 stopped, 8 zombie` (from the CI run).
2. **Group by parent.** `ps -eo ppid=,stat= | awk '$2 ~ /^Z/ {print $1}' | sort | uniq -c`. In CI all 8 had the same PPID. That parent is the one to look at.
3. **What is the parent?** `ps -o pid,ppid,stat,args -p PPID`, then `ps -o unit= -p PPID` to find the systemd unit (`lab-batch.service`).
4. **Does it handle SIGCHLD?** `grep -E 'SigIgn|SigCgt' /proc/PPID/status`. These are hex bitmasks; signal N is bit N-1. CI showed `SigCgt: 0000000000000002`, so only SIGINT (signal 2) is caught and SIGCHLD (17) is not. No handler and no `wait()` loop means nothing collects the exit status.
5. **Why kill -9 does nothing.** `diagnose.sh` sends `kill -9` to one zombie and reads `/proc/PID/status` again: still `State: Z (zombie)`. The process has already exited. There is no code left to kill, only an entry in the process table holding its exit status for the parent.

## Root cause

The parent forks children and never reaps them (`wait()`/`waitpid()`), and it does not set SIGCHLD to `SIG_IGN` either (which would make the kernel reap them automatically).

## Fix

`fix.sh` switches the parent to the version with a SIGCHLD handler that calls `waitpid(-1, WNOHANG)` in a loop, then restarts the service. Restarting also clears the existing zombies: when a parent dies, its children are re-parented to PID 1 (or the nearest subreaper), which reaps them.

If you cannot change the code right away, restarting the parent is the immediate fix. Killing the zombies never is.

## Prevention

- Always reap children: `waitpid` in a SIGCHLD handler, or a process pool that does it for you.
- In containers, run a real init as PID 1 (`tini`, `docker run --init`), because your app may end up as the parent of orphans it does not reap.
- Alert on the zombie count. A handful is harmless; thousands can exhaust the PID limit (`kernel.pid_max`, or `pids.max` in a cgroup), and then nothing new can start.

## What CI checks

8 zombies exist after `break.sh`. `diagnose.sh` reports the parent PID, its name, the zombie count, the systemd unit, and that `kill -9` did not remove a zombie. After the fix, the service still runs and starts jobs, and there are no `batch-child` zombies.

## Interview questions this covers

- **What is a zombie, and what is an orphan?** A zombie has exited and waits for its parent to read its exit status. An orphan is still running but its parent died; it is adopted by PID 1 or a subreaper.
- **Do zombies use memory or CPU?** No CPU and almost no memory. They hold a PID and a process table entry. The risk is running out of PIDs.
- **How do you get rid of them?** Make the parent call `wait()`, or kill/restart the parent so PID 1 adopts and reaps them.
- **What does `SIGCHLD` set to `SIG_IGN` do?** On Linux, children of that parent are reaped automatically and never become zombies.
- **Why does PID 1 in a container matter?** PID 1 has to reap adopted orphans and forward signals. Many apps do neither.
