# Linux Troubleshooting Lab

Thirteen real faults on a Linux host, each with a script that breaks it, a script that finds the cause with the tools an SRE would reach for, a script that fixes it, and a write-up. CI runs every one of them on a fresh Ubuntu runner and fails if the diagnosis is wrong or the fix does not work.

![linux-troubleshooting-lab](https://github.com/eswarsurya/devops-portfolio/actions/workflows/linux-troubleshooting-lab-ci.yml/badge.svg)

I built it to practise, and to show, two things: Linux internals (processes, threads, memory, file descriptors, filesystems, the kernel's view of a stuck process) and networking (TCP/IP, HTTP, DNS, TLS and packet analysis).

## How each scenario runs

```
run-scenario.sh <name>
  1. break.sh      plant a realistic fault, record what was planted (hidden from diagnose)
  2. verify.sh     must FAIL: proves the fault is real
  3. diagnose.sh   investigate with real tools, print the evidence, report findings
                   -> every planted value must match what diagnose found
  4. fix.sh        resolve it the way you would on a server
  5. verify.sh     must PASS
  6. cleanup.sh    always runs (trap): processes, namespaces, mounts, units, qdiscs
```

`diagnose.sh` works from symptoms only. It does not read what `break.sh` planted; CI greps for that and fails if it does. It finds the PID with `top`/`pidstat`, the OOM kill in the kernel log, the retransmissions in a packet capture, and so on, then prints lines like `FINDING oom_killed=yes`. The runner compares them with the planted values.

## Scenarios

| Scenario | Symptom | Tools used | What CI proves |
|---|---|---|---|
| [cpu-runaway](scenarios/cpu-runaway) | Box is slow, high CPU | `vmstat`, `top`, `pidstat`, `ps -L`, `top -H`, `/proc/<pid>/task/*/stat` | Finds the planted PID and that exactly 2 of its threads are spinning; after SIGTERM no process uses more than 80% of a CPU |
| [oom-killed-in-cgroup](scenarios/oom-killed-in-cgroup) | Worker keeps restarting, host has free RAM | `journalctl -u`, `journalctl -k`, cgroup v2 `memory.max` / `memory.events` / `memory.peak`, `systemctl show` | A leak in a `MemoryMax=64M` systemd service is OOM-killed; finds the unit, the killed process and the limit from the kernel log and cgroup files; after bounding the cache, 0 OOM kills |
| [zombie-processes](scenarios/zombie-processes) | Growing list of `<defunct>` | `ps` (STAT `Z`, PPID), `top`, `/proc/<pid>/status` SigCgt, `ps -o unit=` | Finds the parent PID and its unit, shows `kill -9` does not remove a zombie; after adding a SIGCHLD handler, 0 zombies |
| [fd-exhaustion](scenarios/fd-exhaustion) | "Too many open files" | `/proc/<pid>/fd`, `/proc/<pid>/limits`, `prlimit`, `lsof -p` | Finds the PID, its limit (128), the leaked file and `EMFILE`; after the fix the fd count stays flat |
| [deleted-file-still-open](scenarios/deleted-file-still-open) | Disk full, `du` disagrees with `df` | `df`, `du`, `lsof +L1`, `/proc/<pid>/fd`, truncate via `/proc`, SIGHUP | Finds the PID, fd and deleted path holding 40 MiB on a loop-mounted ext4; after truncating and SIGHUP, `df` and `du` agree |
| [inode-exhaustion](scenarios/inode-exhaustion) | "No space left on device", `df -h` shows space | `df -i`, `stat -f`, `find -printf '%h'` | Finds the filesystem at 100% inode use and the directory holding the files; after cleanup, writes work |
| [blocked-on-fifo](scenarios/blocked-on-fifo) | Process alive but doing nothing | `ps` STAT/WCHAN, `/proc/<pid>/stack`, `strace -p`, `/proc/<pid>/fd`, `lsof`, `/proc/<pid>/fdinfo` | Finds the blocked syscall (`read`), the FIFO, and the PID of the stuck writer; after replacing the producer, jobs are processed |
| [dns-hosts-override](scenarios/dns-hosts-override) | Name resolves, app still can't connect | `curl -v`, `dig`, `getent`, `nsswitch.conf`, `ip neigh` | `dig` and `getent` disagree; finds the stale `/etc/hosts` line; after removing it the request succeeds |
| [wrong-bind-address](scenarios/wrong-bind-address) | "Connection refused" from clients only | `curl`, `ping`, `ss -ltnp` | Finds the service listening on `127.0.0.1:8080` and its process; after rebinding the client connects |
| [firewall-drop-vs-reject](scenarios/firewall-drop-vs-reject) | One port hangs, one port refuses | `curl` timings, `tcpdump`, `tshark`, `ss`, `nft list ruleset` counters | Timeout vs refused, the DROP and REJECT rule ports, no SYN-ACK vs RST in the capture; after removing the rules both work |
| [packet-loss-and-latency](scenarios/packet-loss-and-latency) | Slow, stalling downloads | `ping`, `ss -ti`, `nstat`, `tcpdump`, `tshark` (`tcp.analysis.retransmission`), `tc -s qdisc` | Finds the netem qdisc (namespace, interface, 40 ms, 5%), retransmissions in kernel counters and in the tshark analysis; after removing it, 0% loss and RTT under 10 ms |
| [tls-expired-certificate](scenarios/tls-expired-certificate) | "SSL certificate problem" | `curl -v`, `openssl s_client`, `openssl x509 -dates -checkend` | curl exit 60, verify code 10, the exact expiry date, and that the hostname is right; after reissuing, verification passes with 30+ days left |
| [http-502-upstream-down](scenarios/http-502-upstream-down) | 502 Bad Gateway | `curl -si`, nginx error log, `nginx -T`, `ss -ltnp` | Status 502, the upstream address and "connection refused" from the nginx log, nothing listening upstream; after restarting it, 200 |

The network scenarios build isolated "hosts" with network namespaces and veth pairs (`ip netns`), so a client, a router and a server can run on one machine without touching the runner's own network or firewall.

## Evidence in CI

[The workflow](../../.github/workflows/linux-troubleshooting-lab-ci.yml) runs each scenario as its own job on `ubuntu-latest`:

- The **job summary** shows a table of planted vs found values for every scenario, plus the full diagnose output.
- The **artifacts** (`evidence-<scenario>`) hold every stage's log, and for the firewall and packet-loss scenarios a `.pcap` you can open in Wireshark.
- A final step fails the job if anything was left behind: network namespaces, mounts, `lab-*` systemd units or lab processes.
- Failures are reported as annotations with the last lines of the failing stage's log.

A lint job runs ShellCheck on every script, checks the Python compiles, and checks that every scenario has all its files and that no `diagnose.sh` or `verify.sh` reads the planted answer.

## Run it yourself

You need an Ubuntu 22.04/24.04 machine or VM you can break (root, systemd, cgroup v2). Do not use a production host.

```bash
sudo apt-get install -y tcpdump tshark strace sysstat lsof dnsutils iproute2 iputils-ping \
  nftables dnsmasq-base nginx psmisc gcc
cd projects/linux-troubleshooting-lab
./run-scenario.sh --list
sudo ./run-scenario.sh packet-loss-and-latency
```

Or step through one by hand, which is the better way to learn it:

```bash
sudo bash scenarios/zombie-processes/break.sh
# investigate yourself first, then compare with:
sudo bash scenarios/zombie-processes/diagnose.sh
sudo bash scenarios/zombie-processes/fix.sh
sudo bash scenarios/zombie-processes/cleanup.sh
```

Logs and captures go to `/tmp/linux-lab/artifacts/<scenario>/`.

## Layout

```
run-scenario.sh            break -> verify (fail) -> diagnose (assert) -> fix -> verify (pass) -> cleanup
lib/lab.sh                 helpers: findings, background processes, namespace pairs, waits
lib/httpd.py               small HTTP/HTTPS server used as the "app" in network scenarios
scenarios/<name>/          break.sh, diagnose.sh, fix.sh, verify.sh, cleanup.sh, README.md
docs/cheatsheet.md         the method, the USE checklist, and how to read ss -ti, vmstat, /proc/meminfo, top
```

## Safety

- Everything that changes the network happens inside network namespaces that are deleted afterwards. The runner's own interfaces, routes and firewall are not touched.
- Filesystem scenarios use small loop-mounted image files under `/srv/linux-lab-*`, never a real disk.
- Memory and fd limits apply to one transient systemd unit, not the host.
- `cleanup.sh` runs on exit even when a stage fails, and CI checks the runner is clean afterwards.

## Limits

- The faults are planted, so the root cause is known in advance. The value is in the method and the tools, not in the mystery.
- One runner plays every host. Real incidents also involve other teams, dashboards and partial information.
- Not covered yet: a process stuck in uninterruptible sleep (`D` state), high load from I/O wait, and an MTU black hole. They need slow block devices or path MTU tricks that I have not yet made reliable on a CI runner.
- Numbers in the scenario write-ups (PIDs, retransmission counts, timings) come from real CI runs and change from run to run.

## Cheat sheet

[docs/cheatsheet.md](docs/cheatsheet.md): the troubleshooting method I follow, the USE method, a first-minute checklist, commands per resource, and how to read the key fields of `ss -ti`, `vmstat`, `/proc/meminfo`, `top` and cgroup memory files.
