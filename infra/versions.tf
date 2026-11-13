terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
  }

  # For a team setup, move state to S3 (see README "Remote state").
}

provider "aws" {
  # Same region as ICEYE's public bucket and SNS topic.
  region = var.region

  default_tags {
    tags = {
      Project   = "sar-tracker"
      ManagedBy = "terraform"
    }
  }
}
