# Memory leak killed by the OOM killer in a cgroup

**Reported symptom:** "The cache service keeps restarting its worker. The host has plenty of free memory, so it can't be memory."

## What `break.sh` does

Starts `lab-cache.service` with `systemd-run` and a cgroup v2 memory limit: `MemoryMax=64M`, `MemorySwapMax=0`. The service is a small supervisor ([supervisor.sh](supervisor.sh)) that runs [cache_worker.py](cache_worker.py) and restarts it 2 seconds after it exits. In `leak` mode the worker caches 2 MiB every 50 ms and never evicts anything. `OOMPolicy=continue` keeps the unit running when a process inside it is OOM-killed, the way a process manager keeps going when one worker dies.

## Investigate

1. **The service log.** `journalctl -u lab-cache.service`. systemd already says it: `A process of this unit has been killed by the OOM killer.` The supervisor logs `cache-worker exited with status 137`. 137 = 128 + 9: killed by SIGKILL.
2. **The kernel log.** `journalctl -k` (or `dmesg`), grep for `oom`. From CI:
   ```
   cache-worker invoked oom-killer: gfp_mask=0xcc0(GFP_KERNEL), order=0, oom_score_adj=0
   oom-kill:constraint=CONSTRAINT_MEMCG,...,oom_memcg=/system.slice/lab-cache.service,task_memcg=/system.slice/lab-cache.service,task=cache-worker,pid=2776,uid=0
   Memory cgroup out of memory: Killed process 2776 (cache-worker) total-vm:80232kB, anon-rss:64768kB, ...
   ```
   `CONSTRAINT_MEMCG` means one cgroup hit its limit. The host was not out of memory. `oom_memcg` names the cgroup; `anon-rss` (64768 kB) is the leak.
3. **The cgroup's own files** under `/sys/fs/cgroup/system.slice/lab-cache.service/`:
   - `memory.max` = `67108864` (64 MiB), `memory.swap.max` = `0`
   - `memory.peak` = `67108864`: it reached the limit
   - `memory.events`: `max 39`, `oom 1`, `oom_kill 1` in the CI run
   - `systemctl show lab-cache.service -p MemoryMax -p MemorySwapMax -p OOMPolicy` confirms where the limit comes from.
4. **Leak or spike?** Sample `memory.current` over a few seconds. In CI, after the supervisor's 2-second pause the new worker went from about 1 MB to 16 MB, 37 MB and 56 MB in 1.5 seconds, then `oom_kill` went from 1 to 2. Steady growth to the limit, again and again, is a leak.

## Root cause

The worker's cache has no upper bound. Its memory grows until it hits the cgroup's `memory.max`, the kernel cannot reclaim enough (anonymous memory, no swap), and the OOM killer kills the largest process in that cgroup.

## Fix

`fix.sh` fixes the leak, not the limit: the cache is bounded to 16 MiB (oldest entries evicted) and the service is restarted. The 64 MiB limit stays as a safety net. Raising the limit would only make the next kill happen later.

## Prevention

- Bound every cache (size or entry count with eviction).
- Alert on `oom_kill` in `memory.events` (or `container_oom_events_total` in Kubernetes) and on restarts.
- Set `MemoryHigh=` a bit below `MemoryMax=` so the kernel throttles and reclaims before it kills, and you get a warning in `memory.events` `high`.

## What CI checks

After `break.sh`, `memory.events` shows an OOM kill. `diagnose.sh` reports, from the kernel log and the cgroup files, the unit (`lab-cache.service`), the killed process name (`cache-worker`), the limit (67108864 bytes) and that an OOM kill happened. After the fix, the service runs for 6 seconds with `oom_kill 0` and memory under 80% of the limit (about 24 MB in CI).

## Interview questions this covers

- **A process exits with 137. What happened?** SIGKILL. In containers and services, the OOM killer is the usual suspect. Check `dmesg` / `journalctl -k` and the cgroup's `memory.events`.
- **The host has free memory but the app is OOM-killed. How?** A cgroup limit (systemd `MemoryMax`, Docker `--memory`, Kubernetes `limits.memory`). The kernel log says `CONSTRAINT_MEMCG`.
- **How does the OOM killer choose a victim?** By `oom_score` (mostly memory use) adjusted by `oom_score_adj` (-1000 to 1000), among the processes in the cgroup or system that is out of memory.
- **What is the difference between `MemoryHigh` and `MemoryMax`?** `MemoryHigh` throttles and reclaims; `MemoryMax` is the hard limit that ends in an OOM kill.
- **Is "free" memory low a problem?** Not by itself. Linux uses free RAM for the page cache. Watch `MemAvailable`, swap activity and OOM events instead.
