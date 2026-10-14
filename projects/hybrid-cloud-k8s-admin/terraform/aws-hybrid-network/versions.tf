terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

provider "aws" {
  region = var.region

  # cost allocation tags on everything, so the bill can be split by team and environment
  default_tags {
    tags = {
      Project     = "hybrid-network"
      Environment = var.environment
      CostCentre  = var.cost_centre
      ManagedBy   = "terraform"
    }
  }
}
