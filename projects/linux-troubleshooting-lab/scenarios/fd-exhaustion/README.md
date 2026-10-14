# File descriptor exhaustion

**Reported symptom:** "Uploads fail with 'Too many open files'. A restart fixes it for a while, then it comes back."

## What `break.sh` does

Starts [upload_api.py](upload_api.py) as `lab-upload-api.service` with `LimitNOFILE=128`. In `leak` mode it opens a price list on every request and never closes it. Within a few seconds `open()` fails with `[Errno 24] Too many open files`.

## Investigate

1. **The error.** `Errno 24` is `EMFILE`: *this process* reached its own limit (`RLIMIT_NOFILE`). `ENFILE` (23) would mean the whole system ran out (`fs.file-max`), which is much rarer.
2. **Which process?** Do not just sort by the number of open descriptors; a busy process with a high limit can be fine. Compare each process's count (`ls /proc/PID/fd | wc -l`) with its own limit (`Max open files` in `/proc/PID/limits`). From CI:
   ```
   USE%  OPEN   LIMIT   PID     COMMAND
   100%  128    128     2971    upload-api
   0%    9      65536   1154    chronyd
   ```
   In the first CI run, a plain count put `Runner.Worker` (182 fds) and `systemd` (153) above `upload-api` (128). That is why the ratio matters.
3. **Its limit.** `grep 'open files' /proc/PID/limits`, `prlimit --pid PID --nofile`, and where it comes from: `systemctl show lab-upload-api.service -p LimitNOFILE` → `128`. `ulimit -n` in your shell shows *your* limit, not the service's.
4. **What are the descriptors?** `ls -l /proc/PID/fd` and `lsof -p PID`. Count by name:
   ```
   lsof -nP -p 2971 | awk 'NR>1 {print $NF}' | sort | uniq -c | sort -rn | head -5
       124 /tmp/linux-lab/state/fd-exhaustion/data/prices.csv
   ```
   The same file open 124 times means an `open()` without a `close()` on every request.

## Root cause

A descriptor leak in the code: each request opens the file and never closes it. 128 is the ceiling, so the service breaks after about 125 requests.

## Fix

`fix.sh` deploys the version that uses `with open(...)`, so the file is closed every time, and restarts the service. After the fix CI saw 4 open descriptors, flat over time. Raising `LimitNOFILE` is fine for services that really need many connections, but on a leak it only delays the same failure.

## Prevention

- Close what you open: `with` in Python, try-with-resources in Java, `defer f.Close()` in Go.
- Watch the ratio of open fds to the limit (`process_open_fds / process_max_fds` in Prometheus client libraries) and alert on a steady climb.
- Set sensible limits in the unit file (`LimitNOFILE=`) rather than in shell profiles, which services do not read.

## What CI checks

After `break.sh` the service log has `EMFILE` errors. `diagnose.sh` reports the PID, the limit (128), the leaked file and `EMFILE`. After the fix there are no errors in the new log and the descriptor count stays under 20 and does not grow over 2 seconds.

## Interview questions this covers

- **"Too many open files". What do you check?** Which process, its limit in `/proc/PID/limits`, its count in `/proc/PID/fd`, then `lsof -p` to see what they are (files, sockets, pipes).
- **Soft vs hard limit?** A process can raise its soft limit up to the hard limit. Only root (CAP_SYS_RESOURCE) can raise the hard limit.
- **Where do limits for a systemd service come from?** `LimitNOFILE=` in the unit (or systemd's default), not `/etc/security/limits.conf`, which applies to PAM logins.
- **Sockets count too?** Yes. Every socket, pipe, eventfd and epoll instance is a file descriptor. Connection leaks often show up as `EMFILE` or many sockets in `CLOSE_WAIT`.
