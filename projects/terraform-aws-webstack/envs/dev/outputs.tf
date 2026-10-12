output "url" {
  description = "Open this in a browser once instances are healthy (~2-3 min)"
  value       = "http://${module.web.alb_dns_name}"
}

output "asg_name" {
  value = module.web.asg_name
}
