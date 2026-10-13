# 0003: No NAT gateway in the Terraform lab

**Status:** accepted for the lab only, Oct 2026 · Project: [terraform-aws-webstack](../../projects/terraform-aws-webstack)

## Context
The production pattern is application instances in private subnets, reaching the internet through a NAT gateway. A NAT gateway is billed every hour it exists, plus data processing, which is the largest cost in a small demo that is applied and destroyed.

## Decision
For the lab, instances run in public subnets with no NAT gateway. Their security group only accepts application traffic from the load balancer's security group (a unit test enforces this), and IMDSv2 is required.

## Consequences
- The lab is cheap to apply for an hour and destroy.
- The instances have public addresses and outbound internet access. That's an accepted lab trade-off, not a design I'd ship.
- For production: private subnets, NAT gateway or VPC endpoints for S3, ECR and SSM, and a reviewed egress policy. The module layout (`envs/dev`, `modules/network`) allows this without rewriting the web module.
