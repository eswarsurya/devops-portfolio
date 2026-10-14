mock_provider "aws" {}

run "cost_saving_defaults" {
  command = plan

  assert {
    condition     = length(aws_nat_gateway.shared) == 1
    error_message = "by default one NAT gateway serves every VPC"
  }
  assert {
    condition     = length(aws_vpc_endpoint.s3) == 3 && alltrue([for e in aws_vpc_endpoint.s3 : e.vpc_endpoint_type == "Gateway"])
    error_message = "every VPC needs a free S3 gateway endpoint so S3 traffic avoids NAT charges"
  }
  assert {
    condition     = length(aws_budgets_budget.monthly.notification) == 4
    error_message = "expected alerts at 50, 80 and 100 percent actual, plus 100 percent forecast"
  }
  assert {
    condition     = one([for r in aws_s3_bucket_lifecycle_configuration.logs.rule : r.expiration[0].days]) == 365
    error_message = "logs must expire after a year"
  }
  assert {
    condition     = aws_flow_log.shared.log_destination_type == "s3"
    error_message = "flow logs should go to S3, which is cheaper than CloudWatch Logs"
  }
}

run "resilient_mode_uses_a_nat_per_az" {
  command = plan

  variables {
    single_nat_gateway = false
  }

  assert {
    condition     = length(aws_nat_gateway.shared) == 2
    error_message = "with single_nat_gateway = false there must be one NAT gateway per AZ"
  }
}
