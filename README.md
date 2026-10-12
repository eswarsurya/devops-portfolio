# DevOps & Cloud Engineering Portfolio

**Eswar Surya Danaboina** · Dublin, Ireland  
**Focus:** DevOps Engineering · AWS Cloud · Infrastructure as Code · CI/CD · Linux Automation · Platform Engineering · AI-assisted operations

One reviewable home for my DevOps labs and AI-assisted operations projects. Each project lives in `projects/<name>/` with its own README (architecture, setup, tests, cleanup) and its own CI workflow in `.github/workflows/<name>-ci.yml`, which only runs when that project changes.

## Flagship projects

| Project | What it is | CI |
|---|---|---|
| [**AIOps Triage Agent**](projects/aiops-triage-agent) | AI on-call assistant: an Alertmanager alert triggers a Claude agent that investigates Kubernetes with **read-only** tools, streams each step live, and proposes a fix that runs **only after human approval** | ![aiops-triage-agent](https://github.com/eswarsurya/devops-portfolio/actions/workflows/aiops-triage-agent-ci.yml/badge.svg) |
| [**Rail Pulse**](projects/rail-pulse) | Live Irish Rail punctuality monitor run as an SRE service: live map, 85% SLO, Prometheus alerts (unit-tested with promtool), Grafana, live-feed contract test | ![rail-pulse](https://github.com/eswarsurya/devops-portfolio/actions/workflows/rail-pulse-ci.yml/badge.svg) |
| [**LLM Gateway**](projects/llm-gateway) | Control plane for company Claude API use: team keys, rate limits, monthly budgets, Irish/EU PII redaction, per-team cache, live cost dashboard | ![llm-gateway](https://github.com/eswarsurya/devops-portfolio/actions/workflows/llm-gateway-ci.yml/badge.svg) |
| [**DevOps MCP Server**](projects/devops-mcp-server) | MCP server giving AI assistants read-only, SSRF-safe checks of sites, TLS, Prometheus, Kubernetes and CI | ![devops-mcp-server](https://github.com/eswarsurya/devops-portfolio/actions/workflows/devops-mcp-server-ci.yml/badge.svg) |

## Foundations

| Project | What it is | CI |
|---|---|---|
| [**Kubernetes GitOps Platform**](projects/k8s-gitops-platform) | Hardened Helm chart, Argo CD app-of-apps, HPA/PDB/NetworkPolicy, kube-prometheus-stack; CI installs it on a real 3-node kind cluster | ![k8s-gitops-platform](https://github.com/eswarsurya/devops-portfolio/actions/workflows/k8s-gitops-platform-ci.yml/badge.svg) |
| [**Terraform AWS Web Stack**](projects/terraform-aws-webstack) | VPC across 2 AZs, ALB and a self-healing ASG as Terraform modules, S3 remote state, `terraform test` with a mocked provider | ![terraform-aws-webstack](https://github.com/eswarsurya/devops-portfolio/actions/workflows/terraform-aws-webstack-ci.yml/badge.svg) |
| [**Docker CI/CD Pipeline**](projects/docker-cicd-pipeline) | Containerised API: lint, test, container smoke test, Trivy scan, GHCR, gated EC2 deploy | ![docker-cicd-pipeline](https://github.com/eswarsurya/devops-portfolio/actions/workflows/docker-cicd-pipeline-ci.yml/badge.svg) |
| [**CI Log Doctor**](projects/ci-log-doctor) | When any project's CI fails, Claude reads the redacted logs and comments root cause and fix on the PR | ![ci-log-doctor](https://github.com/eswarsurya/devops-portfolio/actions/workflows/ci-log-doctor-ci.yml/badge.svg) |
| [**AWS S3 Backup & Restore**](projects/aws-s3-backup) | Bash backup with checksums, encryption, upload verification, IAM role (no keys), lifecycle retention | ![aws-s3-backup](https://github.com/eswarsurya/devops-portfolio/actions/workflows/aws-s3-backup-ci.yml/badge.svg) |
| [**Ansible Linux Hardening**](projects/ansible-linux-hardening) | Ansible role that disables SSH root and password login and installs a host audit script; syntax-checked and linted in CI | ![ansible-hardening](https://github.com/eswarsurya/devops-portfolio/actions/workflows/ansible-hardening-ci.yml/badge.svg) |

**How they fit together:** the pipeline builds the image; Terraform or the GitOps platform runs it; Prometheus watches it; the AIOps agent investigates when it breaks; the MCP server lets an assistant check it safely; the LLM gateway controls what all the AI calls cost; and CI Log Doctor explains any red build in this repo.

## Evidence status

I keep three kinds of evidence separate, and only claim what I can show:

| Evidence | Status |
|---|---|
| **Local tests** | All passing at import: 104 Python tests, 7 Bash tests, 4 Terraform tests, Prometheus alert-rule tests, Kubernetes schema validation of every chart environment |
| **CI (GitHub Actions)** | Runs per project on this repo. The badges above show the current result. |
| **Real cloud / cluster deployment** | **Not yet claimed.** Each README has deploy and teardown steps. I'll add screenshots under each project's `docs/` as I run them. |

Demos that run locally with no cloud account: AIOps Triage (`python -m triage.demo --replay`), Rail Pulse (live Irish Rail data), LLM Gateway (mock upstream), and the MCP server (Claude Code / Claude Desktop).

## Engineering and evidence standards

- Keep one canonical copy of each project; do not duplicate overlapping archive entries.
- Include setup instructions, architecture, tests, troubleshooting, and cleanup steps.
- Separate local test results, CI results, and real VM/cloud deployment evidence.
- Never commit credentials, private keys, real inventories, environment files, or sensitive logs.
- Use least privilege and safe defaults; AI-assisted remediation must fail closed and require approval.
- Do not claim production use or cloud deployment without verifiable evidence.

## Contact

- Email: [eswardanaboina@gmail.com](mailto:eswardanaboina@gmail.com)
- LinkedIn: https://www.linkedin.com/in/eswarsurya76/
- GitHub: https://github.com/eswarsurya
- Existing portfolio: https://eswardanaboina.vercel.app/ (not replaced without review)
