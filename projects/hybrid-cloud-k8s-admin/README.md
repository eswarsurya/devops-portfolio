# hybrid-cloud-k8s-admin

The cloud side of the [on-prem platform lab](../onprem-platform-lab), plus the cluster administration work that keeps
Kubernetes and OpenSearch healthy.

- **AWS hybrid network** in Terraform: Transit Gateway hub, VPC peering, a Site-to-Site VPN back to the on-prem
  data centre, and cost controls built in from the start.
- **Azure**: an AKS cluster in Terraform, and an Azure DevOps build and release pipeline for the same app.
- **GitLab CI**: the same pipeline written for GitLab.
- **Kubernetes administration drills** (the tasks the CKA exam tests) on a real 3-node cluster.
- **OpenSearch cluster administration** on a 3-node cluster: lifecycle policies, snapshots, draining and restarting nodes.

![hybrid-cloud-k8s-admin](https://github.com/eswarsurya/devops-portfolio/actions/workflows/hybrid-cloud-k8s-admin-ci.yml/badge.svg)

## What is proven, and what is not

| Part | How it is checked in CI | Deployed to a real cloud? |
|---|---|---|
| AWS network (TGW, peering, VPN, cost) | `terraform validate` and `terraform test` against a mocked AWS provider | No. Plan-level tests only |
| AKS cluster | `terraform validate` and `terraform test` against a mocked azurerm provider | No |
| Azure DevOps pipeline | Checked against the Azure Pipelines schema | Not run (needs an Azure DevOps organisation) |
| GitLab CI pipeline | Checked against the GitLab CI schema | Not run (needs a GitLab project) |
| Kubernetes drills | **Run for real** on a 3-node kind cluster, every check asserted | Local cluster in CI |
| OpenSearch drills | **Run for real** on a 3-node cluster, every check asserted | Local cluster in CI |

## AWS hybrid network

```
                    on-prem DC (172.30.10.0/24)
                            │  Site-to-Site VPN: 2 IPsec tunnels, IKEv2, AES-256
                            ▼
   ┌──────────────── Transit Gateway (explicit route table) ────────────────┐
   │                                                                        │
 shared VPC 10.0.0.0/16                                        app VPC 10.1.0.0/16 ── peering ── data VPC 10.2.0.0/16
 NAT gateway + internet gateway                                workloads                          databases
 (central egress for every VPC)
```

- **Transit Gateway**: default association and propagation are turned off, so every route is written down and reviewed.
  Spokes send internet traffic to the shared VPC, which owns the only NAT gateway.
- **Site-to-Site VPN**: customer gateway for the on-prem device, VPN attached to the Transit Gateway, static route
  for the on-prem network, IKEv2 with AES-256 / SHA-256 / DH group 14 on both tunnels, and a CloudWatch alarm if a
  tunnel goes down.
- **VPC peering**: the app VPC talks to the data VPC directly. Peering has no per-GB processing charge, so the busiest
  path skips the hub. Peering is not transitive, so the data VPC stays isolated from on-prem and the shared VPC.

### Cost optimisation

| Control | Why |
|---|---|
| One shared NAT gateway (`single_nat_gateway = true`) | NAT gateways are charged per hour and per GB; one serves every VPC. Set it to `false` for one per AZ when resilience matters more |
| S3 gateway endpoints in every VPC | S3 traffic stays off the NAT gateway, and gateway endpoints are free |
| Peering for app ↔ data | No Transit Gateway data processing charge on the busiest path |
| Monthly budget | Alerts at 50%, 80% and 100% of actual spend, and when the forecast passes 100% |
| Cost Anomaly Detection | Daily alert when a service's spend jumps |
| Log lifecycle | Standard → Infrequent Access at 30 days → Glacier Instant Retrieval at 90 → deleted at 365 |
| Flow logs to S3 | Cheaper than CloudWatch Logs; only rejected traffic is logged |
| Cost allocation tags | Every resource tagged with Environment, CostCentre and Project through provider `default_tags` |

## Azure

- **AKS** (`terraform/azure-aks`): Entra ID login with Azure RBAC and local accounts disabled, Azure CNI overlay with
  network policy, workload identity, a system pool for system pods only, an autoscaling user pool across three zones,
  Container Insights, planned weekly patch upgrades, and user-assigned control-plane and kubelet identities created up front, so nodes pull from ACR with the AcrPull role from the first boot (no registry passwords).
- **Azure DevOps** (`pipelines/azure-pipelines.yml`): build stage (lint, unit tests with published results, image build,
  Trivy scan that blocks fixable critical CVEs, push to ACR), then release stages to AKS dev and prod as deployment
  jobs. Production waits for the approval configured on the `aks-prod` environment. The shared release template runs
  `helm upgrade --atomic`, so a failed release rolls itself back, then smoke-tests the service.

## GitLab CI

`pipelines/gitlab-ci.yml` runs the same flow: lint, tests with a JUnit report, image build with Docker-in-Docker,
Trivy scan, then Helm deploys to dev automatically and to prod by a manual step.

## Kubernetes administration drills

[`k8s-admin/run-drills.sh`](k8s-admin/run-drills.sh) runs on a 3-node kind cluster (one control plane, two workers).
Each drill does the task and then asserts the result.

| Drill | What it does and checks |
|---|---|
| RBAC | Role and RoleBinding for a read-only service account; ClusterRole for node access. Checked with `kubectl auth can-i` for allowed and denied actions |
| New user by CSR | Creates a key and CSR for user `jane` in group `developers`, approves it through the Certificates API, builds her kubeconfig, and proves she can deploy in her namespace but cannot read secrets |
| Scheduling | Taints a node, pins a workload to it with a toleration and node affinity, and proves other workloads stay off it |
| Node maintenance | Drains a worker while a PodDisruptionBudget keeps 2 of 3 pods up, checks the pods moved, then uncordons |
| NetworkPolicy | Default-deny ingress for a namespace, then allows only the frontend on port 80. Proves the frontend gets in and other pods are blocked |
| Troubleshooting | Diagnoses a rollout stuck on an image pull error, fixes it, then reverts a second bad release with `kubectl rollout undo` |
| etcd backup and restore | Takes an `etcdctl` snapshot, deletes an object, restores the snapshot with `etcdctl` into a new data directory, points the static etcd pod at it, and proves the object is back |

## OpenSearch cluster administration

[`opensearch/run-admin-drills.sh`](opensearch/run-admin-drills.sh) runs against three OpenSearch 2.17 nodes and Dashboards.

| Drill | What it checks |
|---|---|
| Cluster formation | Green, three nodes, a cluster manager elected |
| Lifecycle | An ISM policy (hot → read-only warm at 2 days → deleted at 7) attaches itself to new `logs-*` indices; an index template sets 3 shards and 1 replica |
| Snapshot and restore | Shared filesystem repository, snapshot, delete the index, restore it, all 500 events back |
| Decommission a node | Shard allocation filtering moves every shard off `os3` while the cluster stays green |
| Node failure | With `os3` stopped, every event is still searchable; the cluster goes back to green when it rejoins |
| Rolling restart | Replica allocation paused, flush, restart `os2`, re-enable allocation, back to green |

## Run it yourself

```bash
# Terraform unit tests (no cloud account needed)
cd terraform/aws-hybrid-network && terraform init -backend=false && terraform test
cd ../azure-aks && terraform init -backend=false && terraform test

# Kubernetes drills (needs Docker, kind and kubectl)
cd k8s-admin && kind create cluster --config kind-cluster.yaml && ./run-drills.sh
kind delete cluster --name hybrid

# OpenSearch drills (needs Docker)
sudo sysctl -w vm.max_map_count=262144
cd opensearch && docker compose up -d && ./run-admin-drills.sh && docker compose down -v
```

## Trade-offs

- **Nothing here is deployed to AWS or Azure.** The Terraform is tested at plan level with mocked providers, which
  proves the logic (routes, counts, settings) but not that every value is accepted by the real APIs.
- **The VPN uses static routes.** BGP would let routes update on their own and is what I would use with a real device.
- **OpenSearch security is off** in the lab to keep the drills short. A real cluster needs TLS and the security plugin.
- **The etcd restore drill uses a single-member etcd**, as kind does. A multi-member restore needs every member
  restored from the same snapshot with a new cluster token.
