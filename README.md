# DevOps & Cloud Engineering Portfolio

**Eswar Surya Danaboina** · Dublin, Ireland  
**Focus:** Site Reliability Engineering · Kubernetes · Linux & networking · Go · Distributed systems · Hybrid cloud (AWS, Azure, GCP, on-prem) · Infrastructure as Code · CI/CD · AI-assisted operations

One reviewable home for my DevOps labs and AI-assisted operations projects. Each project lives in `projects/<name>/` with its own README (architecture, setup, tests, cleanup) and its own CI workflow in `.github/workflows/<name>-ci.yml`, which only runs when that project changes.

## Flagship projects

| Project | What it is | CI |
|---|---|---|
| [**Go Replicated KV**](projects/go-replicated-kv) | Distributed key-value store in Go (standard library only): 3 replicas, quorum reads and writes, read repair, write-ahead log and catch-up after restart. SLO with burn-rate alerts tested in promtool, k6 load test and capacity plan, and a game day in CI that kills nodes, checks the page fires and clears, with a postmortem | ![go-replicated-kv](https://github.com/eswarsurya/devops-portfolio/actions/workflows/go-replicated-kv-ci.yml/badge.svg) |
| [**Linux Troubleshooting Lab**](projects/linux-troubleshooting-lab) | 13 real faults on Linux, each broken, diagnosed with real tools and fixed in CI: runaway threads, OOM kills in a cgroup, zombies, fd exhaustion, deleted-but-open files, inodes, a process blocked in a syscall (strace), DNS, bind address, firewall DROP vs REJECT, packet loss with tc netem and tshark, expired TLS, 502 from a dead upstream | ![linux-troubleshooting-lab](https://github.com/eswarsurya/devops-portfolio/actions/workflows/linux-troubleshooting-lab-ci.yml/badge.svg) |
| [**Hybrid Cloud & K8s Admin**](projects/hybrid-cloud-k8s-admin) | AWS Transit Gateway, VPC peering, Site-to-Site VPN and cost controls in Terraform; AKS and Azure DevOps pipelines; GitLab CI; CKA-style drills on a 3-node cluster (RBAC, CSR users, drain, NetworkPolicy, etcd backup and restore); OpenSearch cluster administration | ![hybrid-cloud-k8s-admin](https://github.com/eswarsurya/devops-portfolio/actions/workflows/hybrid-cloud-k8s-admin-ci.yml/badge.svg) |
| [**AIOps Triage Agent**](projects/aiops-triage-agent) | AI on-call assistant: an Alertmanager alert triggers a Claude agent that investigates Kubernetes with **read-only** tools, streams each step live, and proposes a fix that runs **only after human approval** | ![aiops-triage-agent](https://github.com/eswarsurya/devops-portfolio/actions/workflows/aiops-triage-agent-ci.yml/badge.svg) |
| [**Grid Signal (GCP)**](projects/gcp-grid-signal) | Live Irish grid carbon intensity on Google Cloud: Cloud Run, Cloud Run Jobs, Scheduler, Firestore, all in Terraform with keyless GitHub deploys, uptime alerts and a budget. Includes a carbon-aware CI gate that holds heavy jobs for a cleaner grid | ![gcp-grid-signal](https://github.com/eswarsurya/devops-portfolio/actions/workflows/gcp-grid-signal-ci.yml/badge.svg) |
| [**Rail Pulse**](projects/rail-pulse) | Live Irish Rail punctuality monitor run as an SRE service: live map, 85% SLO, Prometheus alerts (unit-tested with promtool), Grafana, live-feed contract test | ![rail-pulse](https://github.com/eswarsurya/devops-portfolio/actions/workflows/rail-pulse-ci.yml/badge.svg) |
| [**LLM Gateway**](projects/llm-gateway) | Control plane for company Claude API use: team keys, rate limits, monthly budgets, Irish/EU PII redaction, per-team cache, live cost dashboard | ![llm-gateway](https://github.com/eswarsurya/devops-portfolio/actions/workflows/llm-gateway-ci.yml/badge.svg) |
| [**DevOps MCP Server**](projects/devops-mcp-server) | MCP server giving AI assistants read-only, SSRF-safe checks of sites, TLS, Prometheus, Kubernetes and CI | ![devops-mcp-server](https://github.com/eswarsurya/devops-portfolio/actions/workflows/devops-mcp-server-ci.yml/badge.svg) |

## Foundations

| Project | What it is | CI |
|---|---|---|
| [**Kubernetes GitOps Platform**](projects/k8s-gitops-platform) | Hardened Helm chart, Argo CD app-of-apps, HPA/PDB/NetworkPolicy, kube-prometheus-stack; CI validates deployment on a 3-node local Kind cluster in the GitHub Actions runner | ![k8s-gitops-platform](https://github.com/eswarsurya/devops-portfolio/actions/workflows/k8s-gitops-platform-ci.yml/badge.svg) |
| [**Terraform AWS Web Stack**](projects/terraform-aws-webstack) | VPC across 2 AZs, ALB and a self-healing ASG as Terraform modules, S3 remote state, `terraform test` with a mocked provider | ![terraform-aws-webstack](https://github.com/eswarsurya/devops-portfolio/actions/workflows/terraform-aws-webstack-ci.yml/badge.svg) |
| [**Jenkins Pipeline**](projects/jenkins-pipeline) | Jenkins configured as code (JCasC): test, build, Trivy scan, push, staging, approval, production, with health checks and automatic rollback. CI proves a broken release never reaches production | ![jenkins-pipeline](https://github.com/eswarsurya/devops-portfolio/actions/workflows/jenkins-pipeline-ci.yml/badge.svg) |
| [**Docker CI/CD Pipeline**](projects/docker-cicd-pipeline) | Containerised API: lint, test, container smoke test, Trivy scan, GHCR, gated EC2 deploy | ![docker-cicd-pipeline](https://github.com/eswarsurya/devops-portfolio/actions/workflows/docker-cicd-pipeline-ci.yml/badge.svg) |
| [**CI Log Doctor**](projects/ci-log-doctor) | When any project's CI fails, Claude reads the redacted logs and comments root cause and fix on the PR | ![ci-log-doctor](https://github.com/eswarsurya/devops-portfolio/actions/workflows/ci-log-doctor-ci.yml/badge.svg) |
| [**AWS S3 Backup & Restore**](projects/aws-s3-backup) | Bash backup with checksums, encryption, upload verification, IAM role (no keys), lifecycle retention | ![aws-s3-backup](https://github.com/eswarsurya/devops-portfolio/actions/workflows/aws-s3-backup-ci.yml/badge.svg) |
| [**Ansible Linux Hardening**](projects/ansible-linux-hardening) | Ansible role to disable SSH root login and optionally disable password authentication, plus fail2ban and a host audit script; CI applies it to a fresh Ubuntu 24.04 runner, re-runs it to prove nothing changes, and checks the result | ![ansible-hardening](https://github.com/eswarsurya/devops-portfolio/actions/workflows/ansible-hardening-ci.yml/badge.svg) |

**How they fit together:** the pipeline builds the image (GitHub Actions, or Jenkins with staged deploys and rollback); Terraform or the GitOps platform runs it; Prometheus watches it; the AIOps agent investigates when it breaks; the MCP server lets an assistant check it safely; the LLM gateway controls what all the AI calls cost; and CI Log Doctor explains any red build in this repo.

## Decisions and incidents

Why things are built the way they are, and what broke and what changed: see [docs/](docs/README.md) for six decision records and two incident write-ups.

## Evidence status

Project validation is reported per project rather than as one combined test total. Test coverage, prerequisites, and commands are documented in each project README; the workflow badges above link to the current GitHub Actions status for each project.

| Evidence type | How to verify it |
|---|---|
| **Local tests** | Run the commands in the relevant project README. Local results depend on the versions and prerequisites installed on your machine. |
| **CI (GitHub Actions)** | Use each project’s badge above to open its workflow and inspect the latest run and logs. A passing CI run proves only the checks in that workflow passed. |
| **Real cloud / VM deployment** | **Not claimed unless explicitly documented with evidence.** Each README includes deployment and teardown steps where applicable. Screenshots or logs will be added under the project’s `docs/` directory after a run is completed. |

Demos intended to run locally without creating cloud resources include AIOps Triage (`python -m triage.demo --replay`), LLM Gateway (mock upstream), and the MCP server in its documented local mode. Rail Pulse uses live Irish Rail data, so its behaviour depends on that external feed being available.

## Engineering and evidence standards

- Keep one canonical copy of each project; do not duplicate overlapping archive entries.
- Include setup instructions, architecture, tests, troubleshooting, and cleanup steps.
- Separate local test results, CI results, and real VM/cloud deployment evidence.
- Never commit credentials, private keys, real inventories, environment files, or sensitive logs.
- Use least privilege and safe defaults; AI-assisted remediation must fail closed and require approval.
- Do not claim production use or cloud deployment without verifiable evidence.
- Treat security scanner findings as informational unless the workflow explicitly enforces a blocking threshold.

## Contact

- Email: [eswardanaboina@gmail.com](mailto:eswardanaboina@gmail.com)
- LinkedIn: https://www.linkedin.com/in/eswarsurya76/
- GitHub: https://github.com/eswarsurya
- Existing portfolio: https://eswardanaboina.vercel.app/ (not replaced without review)
