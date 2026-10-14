# Name resolves to the wrong address (/etc/hosts override)

**Reported symptom:** "The client can't reach `api.lab.internal`. I checked DNS with `dig` and it returns the right address."

## Topology

```
lab-dns-cli  10.201.0.10  <-- veth -->  lab-dns-srv  10.201.0.1  dnsmasq (DNS)
                                                     10.201.0.2  orders-api :8080
```

Two network namespaces joined by a veth pair. The client's `/etc/resolv.conf`, `/etc/hosts` and `/etc/nsswitch.conf` come from `/etc/netns/lab-dns-cli/`, which `ip netns exec` bind-mounts over `/etc` inside the namespace. The runner's own files are never touched.

## What `break.sh` does

DNS (dnsmasq) correctly answers `api.lab.internal → 10.201.0.2`. But the client's `/etc/hosts` still has a line from an old migration: `10.201.0.99 api.lab.internal`. Nothing uses 10.201.0.99 any more.

## Investigate

1. **What address does the app actually use?** `curl -sv` prints it. From CI:
   ```
   * IPv4: 10.201.0.99
   *   Trying 10.201.0.99:8080...
   * connect to 10.201.0.99 port 8080 from 10.201.0.10 port 51320 failed: No route to host
   ```
   "No route to host" after about 3 seconds on a local subnet: ARP got no answer.
2. **What does DNS say?** `dig api.lab.internal` asks the nameserver in `/etc/resolv.conf` directly and returned `10.201.0.2`.
3. **What does the system resolver say?** `getent ahostsv4 api.lab.internal` resolves the way applications do (glibc, following `/etc/nsswitch.conf`) and returned `10.201.0.99`.
4. **They disagree, so look at the order.** `grep ^hosts: /etc/nsswitch.conf` → `hosts: files dns`. `files` (`/etc/hosts`) is checked first and wins. `grep -n api.lab.internal /etc/hosts` shows the stale line.
5. **Is the old address alive?** `ping` gets no reply and `ip neigh show 10.201.0.99` shows `INCOMPLETE`: no host has that address.

## Root cause

A stale `/etc/hosts` entry overrides DNS for that name.

## Fix

`fix.sh` removes the line (keeping a copy of the old file). `getent` then returns `10.201.0.2` and the request works.

## Prevention

- Do not hand-edit `/etc/hosts` on servers. If you must, manage it with config management so stale entries are visible and reviewed.
- When debugging names, always compare `getent hosts` (what apps see) with `dig` (what DNS says).
- Remember caches: systemd-resolved (`resolvectl flush-caches`), nscd, and JVMs that cache DNS answers.

## What CI checks

After `break.sh`, `curl http://api.lab.internal:8080/` from the client fails. `diagnose.sh` reports the address `getent` returns, the address DNS returns, the cause (`hosts_file_override`) and the exact stale line. After the fix, the request returns `orders-api ok`.

## Interview questions this covers

- **`dig` works but the app fails. Why?** `dig` only asks DNS. Apps use the system resolver, which follows `nsswitch.conf` (`/etc/hosts`, then DNS, maybe mDNS or systemd-resolved). Use `getent hosts`.
- **What is in `/etc/resolv.conf` on Ubuntu?** Usually `nameserver 127.0.0.53`, the systemd-resolved stub. `resolvectl status` shows the real upstream servers.
- **What does "No route to host" mean on a local network?** The kernel tried ARP and nobody answered, so the target address is not in use (or a firewall sends ICMP host-unreachable).
- **How does `ip netns exec` give a namespace its own resolv.conf?** It bind-mounts files from `/etc/netns/<name>/` over `/etc` in a private mount namespace for that command.
