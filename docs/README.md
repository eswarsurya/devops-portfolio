# Decisions and incident write-ups

Short records of why things are built the way they are, and what went wrong and what changed because of it.

## Decision records

| # | Decision |
|---|---|
| [0001](decisions/0001-monorepo-with-per-project-ci.md) | One repository, one CI workflow per project |
| [0002](decisions/0002-argo-cd-pull-based-gitops.md) | Argo CD pulls from git instead of CI pushing to the cluster |
| [0003](decisions/0003-no-nat-gateway-in-the-terraform-lab.md) | No NAT gateway in the Terraform lab |
| [0004](decisions/0004-health-check-and-rollback-on-every-deploy.md) | Every deploy health-checks and rolls back on its own |
| [0005](decisions/0005-ai-tools-read-only-with-human-approval.md) | AI tools get read-only access; changes need a person |

## Incident write-ups

| Date | What happened |
|---|---|
| [12 Oct 2026](postmortems/2026-10-12-ansible-role-undefined-variables.md) | The Ansible role would have failed on every server, while CI was green |
| [13 Oct 2026](postmortems/2026-10-13-image-push-denied-after-repo-move.md) | Image pushes were denied after the repository moved |
