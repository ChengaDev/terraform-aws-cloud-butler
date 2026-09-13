terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

module "whatsapp_assistant" {
  source = "../.."

  name = var.name

  whatsapp_token           = var.whatsapp_token
  whatsapp_verify_token    = var.whatsapp_verify_token
  whatsapp_phone_number_id = var.whatsapp_phone_number_id
  whatsapp_app_secret      = var.whatsapp_app_secret
  allowed_phone_numbers    = var.allowed_phone_numbers

  bedrock_model_id = var.bedrock_model_id

  tags = {
    Environment = "personal"
  }
}
