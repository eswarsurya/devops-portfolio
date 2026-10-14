# SLOs for go-replicated-kv

## Who the SLO is for

Clients that call the key-value API (`GET`, `PUT`, `DELETE /kv/{key}`). Health checks, metrics scrapes and peer-to-peer replication traffic are not part of it.

## SLIs

Both are measured by the nodes themselves, from `kv_http_requests_total` and `kv_http_request_duration_seconds` with `route="kv"`.

| SLI | Good event | Valid event |
|---|---|---|
| Availability | response is not 5xx | every client request |
| Latency | response in under 100 ms | every client request |

A 404 for a missing key and a 400 for a bad key count as good: the service did its job.

## SLOs

Over a rolling 28 days:

| SLO | Target | Error budget |
|---|---|---|
| Availability | 99.9% of requests are not 5xx | 0.1% of requests. At a steady 50 req/s that is about 121,000 failed requests, or about 40 minutes of total outage |
| Latency | 99% of requests complete in under 100 ms | 1% of requests |

The latency target is loose on purpose. In CI the load test measures p95 around 1 ms at 200 req/s, so 100 ms leaves room for a slow disk or a noisy neighbour without paging anyone.

## Alerts

[rules.yml](rules.yml) uses the multiwindow, multi-burn-rate pattern from the Google SRE Workbook.

| Alert | Fires when | Budget spent before it fires | Severity |
|---|---|---|---|
| `KVErrorBudgetBurnFast` | error ratio > 14.4 x 0.1% over 1h **and** 5m | 2% of the month in 1 hour | page |
| `KVErrorBudgetBurnMedium` | error ratio > 6 x 0.1% over 6h **and** 30m | 5% in 6 hours | page |
| `KVErrorBudgetBurnSlow` | error ratio > 0.1% over 3d **and** 6h | 10% in 3 days | ticket |
| `KVLatencyBudgetBurnFast` | slow ratio > 14.4 x 1% over 1h and 5m | 2% in 1 hour | page |
| `KVLatencyBudgetBurnSlow` | slow ratio > 1% over 3d and 6h | 10% in 3 days | ticket |
| `KVNodeDown` | a node is not scraped for 30s | none: the quorum absorbs one node | ticket |
| `KVQuorumLost` | a node reports it cannot reach a quorum | depends on traffic | ticket |

Why two windows: the long window proves the burn is real and large enough to matter. The short window makes the alert clear soon after the problem is fixed, instead of firing for another hour.

Why one node down does not page: with N=3 and W=R=2 the cluster keeps serving with one node gone. It costs no error budget, so it is a ticket for working hours. If losing a node does start to cost budget, the burn-rate alerts page.

## How the rules are tested

[rules_test.yml](rules_test.yml) feeds synthetic counters into `promtool test rules` and checks:

- a healthy service fires nothing
- a total outage pages within minutes (fast and medium burn), and the slow ticket does not fire early
- 1% errors pages through the 6x alert but not the 14.4x one
- 0.2% errors raises only the slow ticket
- 20% slow requests pages through the latency alert
- `KVNodeDown` and `KVQuorumLost` carry the instance label

CI runs this in the `slo-rules` job. The `game-day` job then checks the fast burn alert against real traffic in a running cluster.

## Known gaps

- **Server-side measurement only.** A request sent to a node that is down never reaches any counter. The game day shows this: clients saw more errors than the SLI did. A real deployment would measure at the load balancer or in the client as well.
- **The 3-day window is expensive.** `rate(...[3d])` over raw data is fine at this scale. At real scale I would record 5m rates and build the long windows from those.
- **Short lab intervals.** Prometheus scrapes and evaluates every 5s in the lab so the game day finishes in minutes.
