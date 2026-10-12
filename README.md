# DevOps & Cloud Engineering Portfolio

**Eswar Surya Danaboina** · Dublin, Ireland  
**Focus:** DevOps Engineering · AWS Cloud · Infrastructure as Code · CI/CD · Linux Automation · Platform Engineering

This repository brings together reproducible DevOps labs and AI-assisted operations projects. Each project should include its source code, setup instructions, validation commands, security notes, and clear evidence of what has actually been tested.

## Projects

| Project | Main technologies | Status |
|---|---|---|
| [Ansible Linux Hardening](projects/ansible-linux-hardening/README.md) | Ansible, Linux, SSH configuration, fail2ban | In review; CI syntax/lint passed, real-VM validation pending |
| [AWS S3 Backup & Restore](projects/aws-s3-backup/README.md) | Bash, AWS CLI, S3, checksums, IAM | Import pending |
| [Docker CI/CD Pipeline](projects/docker-cicd-pipeline/README.md) | Docker, FastAPI, GitHub Actions, Trivy, Prometheus | Import pending |
| [Terraform AWS Web Stack](projects/terraform-aws-webstack/README.md) | Terraform, AWS VPC, ALB, ASG, remote state | Import pending |
| [Kubernetes GitOps Platform](projects/k8s-gitops-platform/README.md) | Kubernetes, Helm, Argo CD, Prometheus | Import pending |
| [CI Log Doctor](projects/ci-log-doctor/README.md) | GitHub Actions, Python, LLM-assisted log analysis | Import pending |
| [AIOps Triage Agent](projects/aiops-triage-agent/README.md) | Python, Kubernetes, incident triage, human approval | Import pending |
| [Rail Pulse](projects/rail-pulse/README.md) | API ingestion, SLI/SLO, Prometheus, Grafana | Import pending |
| [LLM Gateway](projects/llm-gateway/README.md) | API gateway, rate limits, budgets, PII redaction | Import pending |
| [DevOps MCP Server](projects/devops-mcp-server/README.md) | MCP, health checks, TLS, Prometheus, read-only tooling | Import pending |

> **Accuracy note:** A project marked “Import pending” is not yet present as a complete project in this repository. Do not treat its link as proof that the code has been published. These imports are the next consolidation task.

## Evidence and security standards

- Document local tests separately from GitHub Actions results and real VM/cloud deployments.
- Never commit credentials, private keys, real inventories, environment files, or sensitive logs.
- Prefer least-privilege IAM/RBAC, safe defaults, and explicit cleanup instructions.
- Treat AI-driven remediation as human-approved and fail-closed by default.
- Do not claim production usage or cloud deployment unless supported by verifiable evidence.

## Contact

- Email: [eswardanaboina@gmail.com](mailto:eswardanaboina@gmail.com)
- LinkedIn: https://www.linkedin.com/in/eswarsurya76/
- GitHub: https://github.com/eswarsurya
- Existing portfolio: https://eswardanaboina.vercel.app/ (live site will not be replaced without review)
