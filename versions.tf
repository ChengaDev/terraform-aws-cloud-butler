terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 6.0 is required for aws_bedrockagentcore_harness (Bedrock Agents
      # Classic, the ~> 5.0 alternative, is closed to new AWS accounts as of
      # July 30, 2026 — see README > Architecture).
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
