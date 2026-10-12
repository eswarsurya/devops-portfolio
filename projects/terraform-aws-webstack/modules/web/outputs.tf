output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "asg_name" {
  value = aws_autoscaling_group.app.name
}

output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}

# Exposed so tests (and reviewers) can check the security posture
output "app_ingress_rules" {
  value = aws_security_group.app.ingress
}

output "imds_tokens" {
  value = aws_launch_template.app.metadata_options[0].http_tokens
}

output "health_check_path" {
  value = aws_lb_target_group.app.health_check[0].path
}
