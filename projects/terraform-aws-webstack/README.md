# terraform-aws-webstack

A web tier on AWS, built with Terraform: a VPC across two availability zones, an Application Load Balancer, and an Auto Scaling Group. State is remote in S3 with locking, and CI runs format checks, validation, unit tests, and a Trivy IaC scan. The scanner currently reports CRITICAL/HIGH findings but does not fail the workflow; see the workflow configuration.

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
envs/dev/tests/       terraform test with a mocked AWS provider (no account needed)
(CI: /.github/workflows/terraform-aws-webstack-ci.yml) fmt + validate + test + Trivy IaC scan
```

## Design decisions

- **Modules + envs split.** Adding `envs/prod` means a new folder with different sizes, not copy-pasted resources.
- **Remote state with locking.** S3 with `use_lockfile` (Terraform 1.10+), so two people can't apply at once. Versioning lets you roll back a broken state file.
- **Security groups reference each other.** The app SG allows only the ALB's SG, not a CIDR. A unit test enforces this.
- **IMDSv2 required.** This reduces exposure to some SSRF-to-metadata credential attacks. It is not a substitute for application-level SSRF defenses.
- **ELB health checks on the ASG.** If the app dies but the VM is fine, the ASG can replace it.
- **Instance refresh.** Changing the image rolls instances gradually, keeping 50% healthy.
- **No NAT gateway.** This avoids the NAT gateway's hourly and data-processing charges in a demo. The instances are in public subnets and require public addressing/egress to pull images and install packages; inbound application traffic is restricted by the instance security group to the ALB. This is a cost-conscious lab trade-off, not a recommended production network design. For production, prefer private application subnets with NAT or appropriate VPC endpoints and a reviewed egress policy.
- **AMI from SSM.** Uses the latest Amazon Linux 2023 image resolved from SSM rather than a hard-coded AMI ID.
- **`default_tags`.** Tags resources for cost tracking and cleanup.

## Test it (no AWS account)

```bash
cd envs/dev
terraform init -backend=false
terraform validate
terraform test
```

The README and test output should be used as the source of truth for the current number of passing tests; do not infer test success from the existence of this documentation.

## Deploy it (costs vary)

AWS charges vary by region, resource usage, data transfer, and account/free-tier eligibility. The ALB and EC2 instances can incur charges while running; the amount is **not guaranteed to stay below €1**, even for a short demonstration. Check current AWS pricing and your Billing console before applying. Set a budget alert if available, record the start time, and destroy resources immediately after testing.

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

# 3. Optional demonstration: terminate one instance and observe ASG replacement.
# This incurs charges while resources are running.
```

## Teardown

```bash
cd envs/dev && terraform destroy
# Only when you're completely done with the project:
# remove prevent_destroy in bootstrap/main.tf, empty the bucket (all versions), then:
cd ../../bootstrap && terraform destroy
```

## What I'd add next

- HTTPS: an ACM certificate plus a 443 listener with an 80→443 redirect.
- Private subnets with VPC endpoints for ECR/SSM, so instances have no public IPs.
- A CloudWatch dashboard and alarms on 5xx and unhealthy host count.
- An `envs/prod` with bigger sizes, plus a plan-on-PR workflow using GitHub OIDC.
