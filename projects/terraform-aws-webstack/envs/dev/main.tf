terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # Remote state in S3 with native S3 locking (Terraform >= 1.10, no DynamoDB needed).
  # bucket is passed at init time:  terraform init -backend-config="bucket=<your-state-bucket>"
  backend "s3" {
    key          = "webstack/dev/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  # Every resource gets these tags - easy to find (and delete) in Cost Explorer
  default_tags {
    tags = {
      Project     = "terraform-aws-webstack"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = "eswar"
    }
  }
}

module "network" {
  source = "../../modules/network"
  name   = "webstack-dev"
}

module "web" {
  source            = "../../modules/web"
  name              = "webstack-dev"
  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.public_subnet_ids
  container_image   = var.container_image
  container_port    = var.container_port
  health_check_path = var.health_check_path
  min_size          = 2
  max_size          = 4
}
