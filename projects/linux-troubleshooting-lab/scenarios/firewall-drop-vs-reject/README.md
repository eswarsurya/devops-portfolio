# Firewall: DROP vs REJECT

**Reported symptom:** "orders-api hangs and then times out. billing-api says 'connection refused' straight away. Both teams say their app is up."

## Topology

```
lab-fw-cli  10.203.0.10  <-- veth -->  lab-fw-srv  10.203.0.1  orders-api  :8080
                                                                billing-api :8081
```

## What `break.sh` does

Starts both apps, then loads leftover "maintenance" rules into nftables **inside the server's namespace** (the runner's own firewall is untouched):

```
tcp dport 8080 counter drop
tcp dport 8081 counter reject with tcp reset
```

## Investigate

1. **Capture while you test.** `tcpdump -i veth-fw-cli -nn -w firewall-drop-vs-reject.pcap 'tcp port 8080 or tcp port 8081'` on the client. CI uploads this file as a build artifact, so you can open it in Wireshark.
2. **Time both connections.** `curl --connect-timeout 3 -w 'time_total=%{time_total}s'`. From CI:
   ```
   port 8080: curl exit 28, time_connect=0.000000s time_total=3.002279s
   port 8081: curl exit 7, time_connect=0.000000s time_total=0.000106s
   ```
   Exit 28 is a timeout: nobody answered. Exit 7 is "couldn't connect": refused at once.
3. **Read the capture.** `tcpdump -nn -r` on the pcap. Port 8080 shows the same SYN sent three times about one second apart (the kernel's SYN retries) and no reply. Port 8081 shows one SYN and an immediate `[R.]` (RST, ACK) from the server. `tshark -Y 'tcp.flags.reset == 1 || tcp.analysis.retransmission'` labels the repeated SYNs `[TCP Retransmission]`.
4. **Are the apps listening?** On the server, `ss -ltnp` shows both on `0.0.0.0:8080` and `0.0.0.0:8081`. The apps are fine.
5. **The firewall.** `nft -a list ruleset` on the server shows both rules, and the counters prove they matched our packets:
   ```
   tcp dport 8080 counter packets 6 bytes 360 drop # handle 2
   tcp dport 8081 counter packets 1 bytes 60 reject with tcp reset # handle 3
   ```
   On iptables hosts: `iptables -L -n -v --line-numbers` gives the same per-rule counters.

## Root cause

Leftover firewall rules. DROP silently discards the packet, so the client waits and retries until it gives up. REJECT answers with a TCP reset, so the client fails at once with "connection refused".

## Fix

`fix.sh` deletes the leftover table. Both apps answer again. On a real host, remove the rules through whatever manages the firewall (Ansible, cloud security groups, Kubernetes NetworkPolicy), or they come back on the next run.

## Prevention

- Manage firewall rules as code and review changes.
- Give maintenance rules an owner and an expiry.
- Know your environment's defaults: AWS security groups and most cloud firewalls DROP, so a block looks like a timeout, not a refusal.

## What CI checks

After `break.sh` both requests fail. `diagnose.sh` reports a timeout on 8080 and "refused" on 8081, finds the DROP rule port and the REJECT rule port in the live ruleset, and confirms from the capture that 8080 never sent a SYN-ACK and 8081 sent a RST. After the fix, both return `ok`.

## Interview questions this covers

- **DROP or REJECT: which is better?** REJECT fails fast and is friendlier inside your own network. DROP gives an attacker less information and is common at the edge. Either way, know which one you use, because the symptoms differ.
- **A connection hangs. How do you tell firewall from app?** Capture: SYNs with no SYN-ACK point at the network or a firewall. A SYN-ACK followed by silence points at the app.
- **How many times does Linux retry a SYN?** `net.ipv4.tcp_syn_retries` (default 6, roughly two minutes with backoff). curl's `--connect-timeout` cut it to 3 seconds here.
- **How do you see which rule is matching?** Rule counters (`nft list ruleset` with `counter`, `iptables -L -v`), or nftables tracing (`nft monitor trace`).
