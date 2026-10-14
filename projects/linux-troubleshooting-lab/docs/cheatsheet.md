# Linux and networking troubleshooting cheat sheet

A short method I follow on a slow or broken Linux host, plus how to read the outputs that come up most. The scenarios in this lab use these same commands.

## The method

1. **Write down the symptom in the user's words.** "Checkout is slow since 10:00" is better than "the server is broken". It tells you what to measure and when it started.
2. **Ask what changed.** Deploys, config pushes, certificate dates, traffic, disk growth. Most incidents start with a change.
3. **Check every resource with the USE method** (below) before going deep on one theory.
4. **Follow the evidence, one hop at a time.** Client, network, proxy, app, disk. Prove each layer works before blaming the next.
5. **Fix, then verify with the same check that showed the fault.** If `curl` failed, `curl` must pass.
6. **Prevent it.** An alert, a limit, a cleanup job, a test. Write it down.

## USE method (Brendan Gregg)

For every resource, check three things:

| | Question | Example |
|---|---|---|
| **U**tilisation | How busy is it? | CPU 95% busy, disk 80% of the time busy |
| **S**aturation | Is work queuing because it is full? | run queue longer than CPU count, swap use, TCP listen backlog drops |
| **E**rrors | Is anything failing? | `dmesg` errors, NIC drops, `EMFILE`, OOM kills |

Saturation is the one people skip, and often the one that explains the latency.

## "Where is the time going?" checklist

Run these in the first minute:

```bash
uptime                      # load averages: 1, 5, 15 minutes. Rising or falling?
dmesg -T | tail -20         # OOM kills, disk errors, segfaults, link flaps
vmstat 1 5                  # CPU split, run queue, swap, I/O wait
mpstat -P ALL 1 3           # one CPU at 100% while others idle = a single-threaded hot spot
pidstat 1 3                 # which process uses the CPU right now
iostat -xz 1 3              # per-disk %util and await
free -m                     # memory, and how much is page cache
sar -n DEV 1 3              # network throughput per interface
sar -n TCP,ETCP 1 3         # new connections per second, retransmits
top                         # the overview, last because it moves too fast to read
```

Load average counts tasks that are running or waiting to run **and** tasks in uninterruptible sleep (state `D`, usually waiting on disk or NFS). High load with idle CPUs points to I/O, not CPU.

## Commands per resource

| Resource | Utilisation | Saturation | Errors |
|---|---|---|---|
| CPU | `mpstat -P ALL 1`, `top`, `pidstat 1` | `vmstat 1` column `r` above CPU count | `perf`, `dmesg` |
| Threads | `ps -L -p PID`, `top -H -p PID` | `pidstat -t -p PID 1` | `/proc/PID/task/TID/status` |
| Memory | `free -m`, `/proc/meminfo` | `vmstat 1` columns `si`/`so`, PSI in `/proc/pressure/memory` | `dmesg` / `journalctl -k` for "Out of memory", cgroup `memory.events` |
| Disk I/O | `iostat -xz 1` `%util` | `iostat` `aqu-sz`, `await` | `dmesg`, `smartctl` |
| Disk space | `df -h`, `du -sh` | n/a | `ENOSPC`; `df -i` for inodes; `lsof +L1` for deleted-but-open files |
| File descriptors | `ls /proc/PID/fd \| wc -l` | vs `grep 'open files' /proc/PID/limits` | `EMFILE` (per process), `ENFILE` (system) |
| Network | `sar -n DEV 1`, `ip -s link` | `ss -s`, `nstat` `TcpExtListenOverflows` | `ip -s link` drops, `nstat` `TcpRetransSegs` |
| Process state | `ps -eo pid,stat,wchan:32,comm` | many in `D` state | zombies (`Z`), `strace -p PID` |

## Network, layer by layer

```bash
ip -br addr; ip route               # do I have an address and a route?
ping -c 3 <host>                    # is it reachable, what is the RTT, any loss?
getent hosts <name>                 # what the application will resolve (uses /etc/hosts first)
dig <name>                          # what DNS says (asks the nameserver directly)
ss -ltnp                            # on the server: who listens, on which address and port
curl -sv --connect-timeout 3 URL    # the full request: DNS, connect, TLS, HTTP
openssl s_client -connect host:443 -servername host   # the TLS handshake and certificate
tcpdump -i <if> -nn -w file.pcap 'tcp port 443'       # the packets, for Wireshark or tshark
```

Fast reading of a failed connection:

| What you see | Usually means |
|---|---|
| `Connection refused` at once | Host is up, nothing listens on that port (or a firewall REJECTs with a TCP reset) |
| Hangs, then times out | Packets are dropped: firewall DROP, wrong route, or the host is down |
| `No route to host` after about 3s on a local subnet | Nobody answered ARP: the address is not in use |
| `Could not resolve host` | DNS or `/etc/hosts`, not the network |
| `SSL certificate problem` (curl exit 60) | Certificate expired, wrong name, or unknown CA. Check with `openssl s_client` |
| HTTP 502 from a proxy | The proxy could not get a valid response from the upstream (down, refused, or reset) |
| HTTP 504 from a proxy | The upstream was too slow |

## Reading key outputs

### `ss -ti` (one established TCP connection)

```
cubic wscale:7,7 rto:244 rtt:41.2/2.5 mss:1448 cwnd:10 ssthresh:7 bytes_sent:... retrans:0/12 lost:1 ...
```

| Field | Meaning |
|---|---|
| `rtt:41.2/2.5` | Smoothed round-trip time / its variation, in ms |
| `rto` | Retransmission timeout in ms. Grows after timeouts |
| `cwnd` | Congestion window in segments. Small or shrinking after loss = TCP slowed itself down |
| `ssthresh` | Where slow start stops. Set lower after loss |
| `retrans:X/Y` | Segments retransmitted and not yet acknowledged / total retransmits on this connection |
| `lost` | Segments currently presumed lost |
| `unacked` | Segments sent and not yet acknowledged |
| `pacing_rate`, `delivery_rate` | What TCP thinks the path can carry, and what it actually delivered |

Rising `retrans` with a large `rtt` and small `cwnd` points at loss on the path, not a slow server. `nstat -az TcpRetransSegs` gives the total for the whole host (or network namespace).

### `vmstat 1`

```
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
```

| Column | Meaning |
|---|---|
| `r` | Runnable tasks (running or waiting for a CPU). Above the CPU count = CPU saturation |
| `b` | Tasks blocked in uninterruptible sleep, usually I/O |
| `si`, `so` | Memory swapped in and out per second. Any steady value is bad news |
| `bi`, `bo` | Blocks read from and written to disk per second |
| `in`, `cs` | Interrupts and context switches per second |
| `us`, `sy`, `id`, `wa`, `st` | CPU time: user, kernel, idle, waiting for I/O, stolen by the hypervisor |

The first line is an average since boot. Read from the second line on.

### `/proc/meminfo`

| Field | Meaning |
|---|---|
| `MemTotal` | RAM the kernel can use |
| `MemFree` | Completely unused. Low is normal: Linux uses spare RAM as cache |
| `MemAvailable` | What new work can get without swapping. **This is the number to watch** |
| `Buffers`, `Cached` | Page cache. Given back when programs need it |
| `SwapTotal`, `SwapFree` | Swap size and what is left |
| `Dirty` | Data waiting to be written to disk |
| `Slab`, `SReclaimable` | Kernel object caches; the reclaimable part can be freed |
| `AnonPages` | Process memory not backed by files (heap, stacks). Growth here is what a leak looks like |
| `Committed_AS` | Memory promised to processes. Can exceed RAM thanks to overcommit |

### `top`

- **Header:** load average; task counts by state, including `zombie`; the CPU split (`us sy ni id wa hi si st`); memory and swap. `avail Mem` matches `MemAvailable`.
- **Columns:** `PR`/`NI` priority and niceness; `VIRT` (all mapped memory, often huge and harmless), `RES` (resident in RAM, what matters), `SHR` (shared); `S` state; `%CPU` can exceed 100% for a multi-threaded process (100% = one full CPU).
- **Keys:** `1` per-CPU view, `H` threads, `P`/`M` sort by CPU/memory, `c` full command line.
- **Process states:** `R` running, `S` sleeping (waiting for an event), `D` uninterruptible sleep (I/O), `Z` zombie (exited, parent has not called `wait()`), `T` stopped.

### cgroup v2 memory files (`/sys/fs/cgroup/<group>/`)

| File | Meaning |
|---|---|
| `memory.max` | Hard limit. Hitting it triggers reclaim, then the OOM killer inside the group |
| `memory.current` | Usage now |
| `memory.peak` | Highest usage seen (newer kernels) |
| `memory.events` | Counters: `high`, `max` (times the limit was hit), `oom`, `oom_kill` (processes killed) |

A process killed with exit status 137 (128 + 9, SIGKILL) and an `oom_kill` count above zero means the cgroup limit, not the whole machine, ran out.
