# terraform-aws-webstack

A highly available web tier on AWS, built entirely with Terraform: a VPC across two availability zones, an Application Load Balancer, and an Auto Scaling Group that self-heals and scales on CPU. State is remote in S3 with locking, and every change is format-checked, validated, unit-tested and security-scanned in CI.

![terraform-aws-webstack](https://github.com/eswarsurya/devops-portfolio/actions/workflows/terraform-aws-webstack-ci.yml/badge.svg)

## Architecture

```
                        Internet
                           │ :80
                 ┌─────────▼─────────┐
                 │  Application LB   │  sg-alb: 80 from 0.0.0.0/0
                 └───┬───────────┬───┘
         health /health          │  (unhealthy → ASG replaces instance)
   ┌─────────────────┼───────────┼──────────────────┐ VPC 10.0.0.0/16
   │  eu-west-1a     │           │     eu-west-1b    │
   │ ┌───────────────▼─┐   ┌─────▼───────────────┐   │
   │ │ EC2 (AL2023)    │   │ EC2 (AL2023)        │   │ sg-app: 8000 from sg-alb ONLY
   │ │ docker: api     │   │ docker: api         │   │ IMDSv2 enforced
   │ └─────────────────┘   └─────────────────────┘   │
   │        ▲  Auto Scaling Group: min 2, max 4, target CPU 50%
   └────────┼─────────────────────────────────────────┘
            │
   S3: terraform state (versioned, encrypted, native lockfile)
```

The instances run the container image published by my **docker-cicd-pipeline** repo, so the two projects connect: CI builds and pushes the image, and Terraform runs it behind a load balancer.

## Layout

```
bootstrap/            one-time: S3 bucket for remote state (prevent_destroy)
modules/network/      VPC, IGW, 2 public subnets across 2 AZs, routes
modules/web/          SGs, ALB, target group, launch template, ASG, scaling policy
envs/dev/             wires modules together, S3 backend, default tags
envs/dev/tests/       `terraform test` with a mocked AWS provider (no account needed)
(CI: /.github/workflows/terraform-aws-webstack-ci.yml) fmt + validate + test + Trivy IaC scan
```

## Design decisions

- **Modules + envs split.** Adding `envs/prod` means a new folder with different sizes, not copy-pasted resources.
- **Remote state with locking.** S3 with `use_lockfile` (Terraform 1.10+), so two people can't apply at once. Versioning lets you roll back a broken state file.
- **Security groups reference each other.** The app SG allows only the ALB's SG, not a CIDR. A unit test enforces this.
- **IMDSv2 required.** This blocks the SSRF-to-credentials attack (the Capital One breach pattern). It's tested too.
- **ELB health checks on the ASG.** If the app dies but the VM is fine, the ASG still replaces it.
- **Instance refresh.** Changing the image rolls instances gradually, keeping 50% healthy.
- **No NAT gateway.** It costs about $35 a month for a demo. The instances are public-subnet, but unreachable except through the ALB. In production I'd use private subnets plus NAT or VPC endpoints.
- **AMI from SSM.** Always the latest Amazon Linux 2023, never a hard-coded AMI ID.
- **`default_tags`.** Every resource is tagged, so cost tracking and cleanup are easy.

## Test it (no AWS account)

```bash
cd envs/dev
terraform init -backend=false
terraform validate
terraform test        # 4 passed: 2 AZs, ALB-only ingress, IMDSv2, health path, ASG cap
```

## Deploy it (keep it under an hour, costs well under €1)

The ALB is billed by the hour (about €0.025/hr) and t3.micro instances are free-tier eligible. **Apply, screenshot, destroy.**

```bash
# 1. Once: state bucket
cd bootstrap
terraform init && terraform apply -var="state_bucket_name=eswar-tfstate-$RANDOM"

# 2. The stack
cd ../envs/dev
cp terraform.tfvars.example terraform.tfvars      # choose image A or B
terraform init -backend-config="bucket=<bucket from step 1>"
terraform plan -out=tfplan
terraform apply tfplan
curl "$(terraform output -raw url)/health"

# 3. Prove self-healing for your screenshots / demo video:
#    terminate one instance in the console → ALB keeps serving → ASG launches a replacement
```

## Teardown

```bash
cd envs/dev && terraform destroy
# Only when you're completely done with the project:
# remove `prevent_destroy` in bootstrap/main.tf, empty the bucket (all versions), then:
cd ../../bootstrap && terraform destroy
```

## What I'd add next

- HTTPS: an ACM certificate plus a 443 listener with an 80→443 redirect.
- Private subnets with VPC endpoints for ECR/SSM, so instances have no public IPs.
- A CloudWatch dashboard and alarms on 5xx and unhealthy host count.
- An `envs/prod` with bigger sizes, plus a plan-on-PR workflow using GitHub OIDC.
