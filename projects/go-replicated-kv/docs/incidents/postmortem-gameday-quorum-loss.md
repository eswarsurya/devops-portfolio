# Postmortem: quorum lost after two of three nodes died (game day)

> **This was a planned game day in a lab, not a real outage.** The cluster ran in Docker Compose on a GitHub Actions runner, with k6 as the only client. The faults were injected on purpose by [scripts/gameday.sh](../../scripts/gameday.sh), which CI runs on every change. Nobody was really paged and no real users were affected. I wrote it up as a real postmortem because the format is the point.

**Status:** complete · **Severity:** would have paged (`KVErrorBudgetBurnFast`) · **Format:** blameless

The times below are an example from CI run [38609373029](https://github.com/eswarsurya/devops-portfolio/actions/runs/38609373029), measured from when the load started. Every run writes its own timeline to the job summary and the numbers vary a little.

## Summary

Two of the three kv nodes were killed with SIGKILL, 65 seconds apart. Losing the first node cost nothing: writes and reads still reached a quorum of two, and only a ticket alert fired. Losing the second left kv1 alone. From then on kv1 correctly refused every read and write with 503, because it could not confirm data with a second replica. The fast burn-rate alert paged 75 seconds after quorum was lost. Restarting both nodes restored quorum within seconds, the restarted kv3 caught up on a write it had missed, and the page cleared on its own about 5 minutes later.

## Impact

- **Duration of user-facing errors:** about 77 seconds, from losing quorum to all three nodes ready again.
- **Server-side count:** 1,238 of 21,561 client requests failed with 503 over the whole exercise (5.74%).
- **Error budget:** k6 sent 50 req/s, but the servers only counted about 40 req/s, because requests sent to a dead node never reach any server. At the counted rate, a 28-day budget of 0.1% allows about 96,600 failed requests. This exercise used **1.3%** of the month's availability budget, by the server's count.
- **Undercount:** the true client-side impact was higher. Every request k6 sent to kv2 or kv3 while they were down failed with a connection error that no server metric saw. See action item 3.
- **Data:** no acknowledged write was lost. A write accepted while kv3 was down was on kv3 after it restarted.

## Timeline

| Time | Event |
|---|---|
| +00:03 | k6 starts sending 50 req/s across kv1, kv2 and kv3 (80% reads). |
| +01:18 | Baseline check: 5m error ratio 0, no burn-rate alerts. |
| +01:18 | **Fault 1:** kv3 killed with SIGKILL. |
| +01:18 | A write through kv1 succeeds (kv1 + kv2 form the quorum). |
| +01:53 | `KVNodeDown` fires for kv3 as a **ticket**. No page. |
| +02:23 | 5m error ratio still 0. The cluster absorbed the loss of one node, as designed. |
| +02:23 | **Fault 2:** kv2 killed. kv1 is now alone and cannot reach 2 replicas. |
| +02:23 | A read through kv1 returns 503 instead of a value it cannot confirm. |
| +03:38 | **`KVErrorBudgetBurnFast` fires (page)**, 75 s after quorum was lost. 5m error ratio 16%. |
| +03:39 | Mitigation: kv2 and kv3 started again (`docker compose start`). |
| +03:40 | All three nodes report ready. Quorum restored 77 s after it was lost. |
| +03:40 | kv3's local copy has the write made while it was down, pulled by anti-entropy after the restart. |
| +08:30 | `KVErrorBudgetBurnFast` resolves by itself once the 5-minute window is clean. |

## Root cause

The direct cause was the two process kills. The real lesson is about the design: with N=3 and W=R=2, the cluster survives exactly one failure. Two nodes down is a full outage for every key, by design, because the alternative (serving from a single replica) would mean returning data that may be stale and accepting writes that may never reach anyone else.

In a real deployment the risk to look at is anything that can take out two nodes at once: two nodes on the same host, the same rack or the same availability zone, or a bad release rolled out to two nodes before the first one is checked.

## What went well

- **One node down cost nothing**, and the alerting agreed: a ticket, not a page. Nobody would have been woken up for a failure the system handled.
- **Refusing was the right behaviour.** kv1 returned 503 instead of serving possibly stale data, and `/readyz` went to 503 while `/healthz` stayed 200, so an orchestrator would stop routing traffic to it without restarting it.
- **Detection was fast and symptom-based:** 75 seconds from losing quorum to the page, driven by the error ratio users experienced, not by a guess about causes.
- **Recovery was quick and needed no manual data work.** Restarted nodes replayed their WAL and caught up through anti-entropy within seconds.
- **The page cleared on its own** once errors stopped, thanks to the 5-minute short window.

## What went badly

- **The SLI missed part of the impact.** Clients talking to the dead nodes saw connection errors that the server-side SLI never counted.
- **The page fired after the outage was mostly over in this run** (75 s detection vs 77 s outage). That is expected with a `for: 1m` alert, and fine for a long outage, but for short sharp outages the page arrives late. A faster page would also fire more often on blips; this is a trade-off to decide on purpose, not by accident.
- **A rejected write is not a failed write.** A PUT that got 503 while quorum was lost was still stored on kv1 and spread to the other nodes after recovery. Clients that treat 503 as "nothing happened" can be surprised.

## Action items

| # | Action | Owner | Status |
|---|---|---|---|
| 1 | Document that two simultaneous node failures are an outage, and place nodes in separate failure domains (hosts or zones; on Kubernetes, pod anti-affinity plus a PodDisruptionBudget with `maxUnavailable: 1`). | Eswar | Done in README; Kubernetes manifests not built yet |
| 2 | Add the game day to CI so detection and recovery are re-checked on every change. | Eswar | Done (`game-day` job) |
| 3 | Measure availability at the client or load balancer as well as on the servers, so requests to a dead node count against the SLO. | Eswar | Open |
| 4 | Document that a 503 on a write means the outcome is unknown, and that clients should retry with the same value. Make the game day check it. | Eswar | Done (README and `game-day` job) |
| 5 | Add hinted handoff so a node that was down catches up from stored hints instead of waiting for anti-entropy. | Eswar | Open |

## Lessons

- Decide in advance how many failures the system must survive, and test exactly that number and one more.
- Alert on what users feel. The node-down alert was useful context, but the burn-rate alert was the one that mattered.
- Every SLI has a blind spot. Know where yours is.
