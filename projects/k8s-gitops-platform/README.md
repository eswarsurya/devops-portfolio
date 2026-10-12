# k8s-gitops-platform

The incident-api from my **docker-cicd-pipeline** repo, running on Kubernetes the way production teams do it: a hardened Helm chart, **GitOps with Argo CD** (git is the source of truth, and manual changes are reverted automatically), and **Prometheus, Grafana and Alertmanager** with alert rules for the app. CI spins up a real 3-node cluster on every push and tests the chart.

![k8s-gitops-platform](https://github.com/eswarsurya/devops-portfolio/actions/workflows/k8s-gitops-platform-ci.yml/badge.svg)

## Architecture

```
  git push ──► GitHub repo (this one) ◄──── watches ──── Argo CD (in cluster)
                                                             │ syncs
          ┌──────────────────────────────────────────────────┼─────────────────┐
          │ kind cluster: 1 control plane + 2 workers        ▼                 │
          │                                                                    │
          │  ns: monitoring (wave 0)            ns: incident-api-dev (wave 1)  │
          │  ┌─────────────────────────┐        ┌───────────────────────────┐  │
          │  │ Prometheus ─ scrapes ───┼───────►│ Service ─► Pods (spread)  │  │
          │  │ Alertmanager (rules)    │        │ HPA · PDB · NetworkPolicy │  │
          │  │ Grafana dashboards      │        │ ServiceMonitor            │  │
          │  └─────────────────────────┘        └───────────────────────────┘  │
          └────────────────────────────────────────────────────────────────────┘
```

## What the chart does, and why

| Feature | Why it matters |
|---|---|
| Liveness `/health` and readiness `/ready` probes | Restart a hung container, but only take a not-ready pod out of the load balancer |
| `maxUnavailable: 0` rolling updates | Zero-downtime deploys. CI proves it with an upgrade plus a test. |
| **HPA** (autoscaling/v2, CPU 70%, 5-min scale-down window) | Scales out under load without flapping |
| **PodDisruptionBudget** | A node drain or cluster upgrade can't take every replica down at once |
| Topology spread across nodes | One node dying doesn't kill the service |
| **NetworkPolicy** | Only same-namespace pods, Prometheus and the ingress controller can reach the app |
| Non-root, read-only root FS, all capabilities dropped, seccomp, no SA token | Passes Pod Security "restricted" style hardening |
| Requests and limits | The scheduler can place pods properly, and one pod can't starve a node |
| **ServiceMonitor** + alert rules | Prometheus scrapes `/metrics`, and alerts fire on a 5xx rate above 5% or the app being down |
| `values-dev.yaml` / `values-prod.yaml` | One chart, different sizes per environment |

## Run it on your laptop

You'll need Docker, [kind](https://kind.sigs.k8s.io/), kubectl and helm.

```bash
make up          # 3-node cluster
make argocd      # install Argo CD
make bootstrap   # apply the root app; Argo CD deploys monitoring, then the app
make ui          # Argo CD UI on https://localhost:8080 (prints the password)
make grafana     # Grafana on http://localhost:3000
```

**Things to try (and screenshot for your portfolio):**

1. **Self-healing GitOps.** Run `kubectl -n incident-api-dev scale deploy/incident-api-dev --replicas=5`. Argo CD puts it back to what git says within seconds.
2. **Deploy by commit.** Change `replicaCount` in `values-dev.yaml`, push, and watch Argo CD sync it. There's no `kubectl apply` anywhere.
3. **Disruption budget.** Run `make drain-test` and watch pods reschedule while the PDB keeps one running.
4. **Alerting.** Scale the app to 0 and watch `IncidentApiDown` fire in Prometheus (`kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090`).

**Teardown:** `make down`. Everything runs locally, so it costs €0.

> Before `make bootstrap`, make your GHCR image from docker-cicd-pipeline public, or point `image.repository` at any public image. If your GitHub username differs, update `repoURL` in the `argocd/` files.

## CI

| Job | What it checks |
|---|---|
| `static` | `helm lint --strict`, renders **all 4 value files**, and validates each against the Kubernetes 1.31 schemas with kubeconform |
| `kind-test` | Creates a real 3-node kind cluster, installs the chart, waits for rollout, runs `helm test`, does a rolling upgrade, and tests again |

## What I'd add next

- **Argo CD Image Updater**, or a CI step that bumps the image tag in git, for full commit-to-prod GitOps.
- External Secrets Operator instead of the plaintext Grafana password.
- Kyverno policies that block non-compliant pods cluster-wide.
- Running the same chart on **EKS**, provisioned with Terraform (extending terraform-aws-webstack).
