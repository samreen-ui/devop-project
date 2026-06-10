# ============================================================
# main.tf — Root module
# Provisions VPC, EC2 (Jenkins), S3 (artifacts), IAM roles
# ============================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state in S3 with DynamoDB locking
  backend "s3" {
    bucket         = "samreen-terraform-state"
    key            = "user-service/terraform.tfstate"
    region         = "ap-south-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "user-service"
      ManagedBy   = "Terraform"
      Environment = var.environment
      Owner       = "samreen-devops"
    }
  }
}

# ── VPC ─────────────────────────────────────────────────────
module "vpc" {
  source = "./modules/vpc"

  environment         = var.environment
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidrs = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones  = var.availability_zones
}

# ── EC2 (Jenkins master) ────────────────────────────────────
module "ec2" {
  source = "./modules/ec2"

  environment      = var.environment
  vpc_id           = module.vpc.vpc_id
  subnet_id        = module.vpc.private_subnet_ids[0]
  instance_type    = var.jenkins_instance_type
  key_name         = var.key_name
  security_group_ids = [module.vpc.jenkins_sg_id]
  iam_instance_profile = module.iam.jenkins_instance_profile_name

  depends_on = [module.vpc, module.iam]
}

# ── S3 (artifact & state buckets) ───────────────────────────
module "s3" {
  source = "./modules/s3"

  environment          = var.environment
  artifact_bucket_name = "samreen-artifacts-${var.environment}"
  logs_bucket_name     = "samreen-logs-${var.environment}"
}

# ── IAM roles & policies ─────────────────────────────────────
module "iam" {
  source = "./modules/iam"

  environment          = var.environment
  artifact_bucket_arn  = module.s3.artifact_bucket_arn
  logs_bucket_arn      = module.s3.logs_bucket_arn
}
