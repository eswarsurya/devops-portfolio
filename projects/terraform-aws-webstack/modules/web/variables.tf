variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "An ALB needs subnets in at least two AZs."
  }
}

variable "container_image" {
  type        = string
  description = "Public image the instances run"
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "min_size" {
  type    = number
  default = 2
}

variable "max_size" {
  type    = number
  default = 4

  validation {
    condition     = var.max_size <= 6
    error_message = "Keep max_size <= 6 in a demo account to cap cost."
  }
}

variable "cpu_target" {
  type    = number
  default = 50
}

variable "tags" {
  type    = map(string)
  default = {}
}
