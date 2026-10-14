variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "cost_centre" {
  description = "Cost centre tag for cost allocation reports"
  type        = string
  default     = "platform"
}

variable "azs" {
  description = "Availability zones to spread subnets across"
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b"]
}

variable "vpc_cidrs" {
  description = "shared = central egress and shared services, app = workloads, data = databases"
  type        = map(string)
  default = {
    shared = "10.0.0.0/16"
    app    = "10.1.0.0/16"
    data   = "10.2.0.0/16"
  }
}

variable "onprem_cidr" {
  description = "Network behind the on-prem VPN gateway (the on-prem platform lab's network)"
  type        = string
  default     = "172.30.10.0/24"
}

variable "onprem_public_ip" {
  description = "Public IP of the on-prem VPN device"
  type        = string
  default     = "203.0.113.10" # documentation range; replace with the real device
}

variable "onprem_bgp_asn" {
  type    = number
  default = 65010
}

variable "single_nat_gateway" {
  description = "One shared NAT gateway for all VPCs (cheaper) instead of one per AZ (more resilient)"
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  type    = number
  default = 200
}

variable "budget_alert_emails" {
  type    = list(string)
  default = ["platform-alerts@example.com"]
}

variable "budget_alert_thresholds" {
  description = "Percent of the monthly budget at which to alert"
  type        = list(number)
  default     = [50, 80, 100]
}
