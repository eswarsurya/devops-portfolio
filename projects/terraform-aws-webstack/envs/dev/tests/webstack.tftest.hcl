# Unit tests: run with `terraform test` - uses a mocked AWS provider,
# so no AWS account or credentials are needed and nothing is created.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }

  # The provider validates these formats, so random mock strings won't do
  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/app/mock/abc123"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/mock/abc123"
    }
  }

  mock_resource "aws_launch_template" {
    defaults = {
      id = "lt-0123456789abcdef0"
    }
  }
}

run "network_spans_two_azs" {
  command = plan

  assert {
    condition     = length(module.network.public_subnet_ids) == 2
    error_message = "Expected exactly two public subnets (one per AZ)."
  }
}

run "app_only_reachable_from_alb" {
  command = apply # apply against the mock so computed IDs are known

  assert {
    condition = alltrue([
      for rule in module.web.app_ingress_rules : try(length(rule.cidr_blocks), 0) == 0
    ])
    error_message = "App security group must not allow CIDR ingress - ALB only."
  }

  assert {
    condition     = module.web.imds_tokens == "required"
    error_message = "IMDSv2 must be enforced on instances."
  }
}

run "health_check_uses_configured_path" {
  command = plan

  variables {
    health_check_path = "/ready"
  }

  assert {
    condition     = module.web.health_check_path == "/ready"
    error_message = "Target group health check should follow var.health_check_path."
  }
}

run "rejects_oversized_asg" {
  command = plan

  module {
    source = "../../modules/web"
  }

  variables {
    name            = "test"
    vpc_id          = "vpc-123"
    subnet_ids      = ["subnet-a", "subnet-b"]
    container_image = "nginx"
    max_size        = 20
  }

  expect_failures = [var.max_size]
}
