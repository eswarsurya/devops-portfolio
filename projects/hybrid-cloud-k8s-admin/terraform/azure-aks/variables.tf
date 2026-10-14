variable "subscription_id" {
  type    = string
  default = "00000000-0000-0000-0000-000000000000" # placeholder; set the real one in tfvars
}

variable "location" {
  type    = string
  default = "northeurope" # Dublin
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}

variable "system_node_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "user_node_size" {
  type    = string
  default = "Standard_D4s_v5"
}

variable "user_pool_min" {
  type    = number
  default = 1
}

variable "user_pool_max" {
  type    = number
  default = 5
}

variable "admin_group_object_ids" {
  description = "Entra ID groups that get cluster-admin through Azure RBAC"
  type        = list(string)
  default     = []
}
