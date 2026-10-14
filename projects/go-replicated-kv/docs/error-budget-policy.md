# Error budget policy

This is the policy I would agree with a team that owns this service. The SLOs and budgets are defined in [slo/README.md](../slo/README.md).

## The idea

The SLO says how unreliable the service is allowed to be. The error budget is that allowance: 0.1% of requests for availability, 1% for latency, over a rolling 28 days. While budget is left, we ship features at normal speed. When it runs out, reliability work comes first until it is back.

The budget is not a target to spend. It is a shared, agreed way to decide between "ship the feature" and "fix the flaky thing", so that decision is not an argument every time.

## Budget states

Budget remaining is read from Prometheus at the weekly ops review:

```promql
1 - (
  sum(increase(kv_http_requests_total{route="kv",code=~"5.."}[28d]))
  / sum(increase(kv_http_requests_total{route="kv"}[28d]))
) / 0.001
```

| Budget left | State | What happens |
|---|---|---|
| more than 50% | normal | Releases go out as usual. Planned risky work (migrations, game days) is fine. |
| 25% to 50% | caution | Releases still go out, with a canary and a person watching the burn-rate graph. No game days. The next sprint includes at least one reliability fix. |
| less than 25% | at risk | Only low-risk releases (bug fixes, config) and anything that improves reliability. New features wait. |
| 0% or less | exhausted | Feature freeze until the 28-day window shows budget again. Only fixes for the causes of the lost budget, and security fixes, are released. |

## Rules that apply in every state

- **Every page gets a review.** Each `severity: page` alert gets a short write-up within five working days. Incidents that used more than 20% of the budget get a full blameless postmortem with action items (see [incidents/](incidents/)).
- **Action items have owners and dates.** Postmortem action items go into the backlog with one owner each. They are reviewed weekly until closed.
- **Security fixes are never frozen.**
- **The budget is not reset for "bad luck".** If a dependency or a cloud provider outage spent the budget, it still counts. The fix may be to depend on it differently.
- **Planned work counts too.** A game day that causes real errors spends real budget. Plan it when there is budget to spare, and keep it short. The game day in CI runs on a throwaway lab cluster, so it spends nothing real.

## If the SLO itself is wrong

If the team keeps freezing releases and users are not unhappy, the SLO may be too strict. If users complain while the budget looks healthy, it is too loose or the SLI measures the wrong thing. Either way, change the SLO on purpose at a quarterly review, write down why, and do not change it in the middle of an incident to make an alert go away.

## Escalation

If the team and the product owner disagree on applying this policy, the engineering manager decides, and the decision is written down in the review notes.
