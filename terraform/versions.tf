terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  # Uses AWS CLI configuration (aws configure)
}

# CloudFront requires ACM certificates in us-east-1 (only used when use_custom_domain = true)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}