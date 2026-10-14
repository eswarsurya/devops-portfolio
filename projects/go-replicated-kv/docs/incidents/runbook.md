# Runbook: go-replicated-kv

For whoever is on call. Every alert in [slo/rules.yml](../../slo/rules.yml) links here.

## Quick facts

- 3 nodes (`kv1`, `kv2`, `kv3`), every node holds every key.
- A write needs 2 nodes (W=2). A read needs 2 nodes (R=2). So **one node down is fine, two nodes down is an outage.**
- Any node can take any client request. There is no leader to fail over.
- Ports per node: `8080` client API, `/healthz`, `/readyz`, `/metrics`; `7070` peer replication; `6060` pprof (not exposed).
- Data lives in a WAL under `/data` on each node. It survives restarts.

## 1. Detect

You were paged by one of these:

| Alert | Meaning |
|---|---|
| `KVErrorBudgetBurnFast` | More than 1.44% of requests are failing. At this rate the monthly budget is gone in about 2 days. |
| `KVErrorBudgetBurnMedium` | More than 0.6% of requests failing for hours. |
| `KVLatencyBudgetBurnFast` | More than 14.4% of requests are slower than 100 ms. |

Tickets (no page): `KVNodeDown`, `KVQuorumLost`, `KVErrorBudgetBurnSlow`, `KVLatencyBudgetBurnSlow`.

## 2. Triage (first 5 minutes)

Acknowledge the page, then answer: **is it still happening, and how bad is it?**

```bash
# Which nodes are up and can they reach a quorum?
for p in 8081 8082 8083; do curl -s localhost:$p/readyz; echo; done

# Error ratio right now (5m) and over the last hour
curl -sG localhost:9090/api/v1/query --data-urlencode 'query=slo:kv_errors:ratio_rate5m'
curl -sG localhost:9090/api/v1/query --data-urlencode 'query=slo:kv_errors:ratio_rate1h'

# Which node is returning the errors, and for which operation?
curl -sG localhost:9090/api/v1/query --data-urlencode \
  'query=sum by (instance, method, code) (rate(kv_http_requests_total{route="kv",code=~"5.."}[5m]))'

# Is replication failing to a particular peer?
curl -sG localhost:9090/api/v1/query --data-urlencode \
  'query=sum by (instance, peer) (rate(kv_replication_failures_total[5m]))'
```

Common patterns:

| What you see | Likely cause |
|---|---|
| 503s, `kv_quorum_failures_total` rising, `/readyz` 503 on the survivors | Two nodes down or cut off from each other |
| `KVNodeDown` for two instances | Two node processes dead (crash, OOM, host gone) |
| All nodes up, 503s, `kv_replication_failures_total` high | Network problem between nodes, or peers too slow (timeouts) |
| Latency alert, no errors | A slow disk (WAL fsync), CPU saturation, or a slow peer. Check the CPU profile. |
| 500s | Storage error writing the WAL (disk full, read-only filesystem). Check logs for `local write`. |

## 3. Mitigate (stop the bleeding first, find the root cause later)

- **Nodes down:** start them. They replay their WAL and then catch up with anti-entropy within one interval (5s in the lab, 10s by default).
  ```bash
  docker compose ps -a
  docker compose start kv2 kv3
  ```
- **Node will not start:** look at its last log lines (`docker compose logs --tail 50 kv2`). A `wal had a torn tail` warning is normal after a crash; the node truncates the half-written entry and continues. If the disk is full, free space or move the volume.
- **Network split:** fix the network first. Do not change W or R to "get writes going": W=1 lets the two sides accept different values for the same key, and last-writer-wins will silently drop one of them when they meet again.
- **Overload / latency:** reduce traffic if a client is misbehaving. Adding a node needs a config change and a restart of every node (there is no live membership change), so it is not a quick fix.
- **Capture evidence before restarting** a slow node if you can: `curl -o cpu.pb.gz localhost:6061/debug/pprof/profile?seconds=30`.

## 4. Communicate

- Within 10 minutes of the page, post in the incident channel: what is broken for users, since when, what you are doing, when the next update is.
- Update every 30 minutes while it is ongoing, even if nothing changed.
- If it lasts more than 30 minutes, or more than one person is working on it, name an incident lead who coordinates and talks to stakeholders, so the person fixing it can focus.

Template:

> **[kv] Degraded:** about X% of reads and writes are failing since HH:MM UTC. Cause: two of three nodes are down. Action: restarting them. Next update HH:MM.

## 5. Resolve

The incident is resolved when:

1. `/readyz` returns 200 on all three nodes,
2. `slo:kv_errors:ratio_rate5m` is back near zero, and
3. the burn-rate alert has cleared by itself (it does, a few minutes after errors stop, because of the 5m window).

Then:

- Note how much budget it used (the impact query in [scripts/gameday.sh](../../scripts/gameday.sh) does this sum).
- Write the postmortem within five working days if it paged. Use [postmortem-gameday-quorum-loss.md](postmortem-gameday-quorum-loss.md) as the template.
- Check the [error budget policy](../error-budget-policy.md): the remaining budget may mean a release freeze.
