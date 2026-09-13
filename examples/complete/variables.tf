variable "aws_region" {
  description = "AWS region to deploy the assistant into. Bedrock Agents are only available in a subset of regions (e.g. us-east-1, us-west-2) — check current AWS docs before changing this."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named profile from ~/.aws/credentials (or config) to authenticate with. Pinning this explicitly, instead of relying on the ambient AWS_PROFILE env var or whatever 'default' happens to resolve to, matters most on a machine with multiple AWS accounts configured — set to null to fall back to the standard credential chain."
  type        = string
  default     = null
}

variable "name" {
  description = "Name prefix applied to every resource created by the module."
  type        = string
  default     = "my-whatsapp-assistant"
}

variable "whatsapp_token" {
  description = "Permanent access token for the Meta WhatsApp Cloud API."
  type        = string
  sensitive   = true
}

variable "whatsapp_verify_token" {
  description = "Secret string of your choosing, used by Meta to verify the webhook during setup."
  type        = string
  sensitive   = true
}

variable "whatsapp_phone_number_id" {
  description = "Phone number ID of the WhatsApp Business sender."
  type        = string
  sensitive   = true
}

variable "whatsapp_app_secret" {
  description = "App Secret of the Meta App, used to verify incoming webhook signatures."
  type        = string
  sensitive   = true
}

variable "allowed_phone_numbers" {
  description = "Allow-list of E.164 phone numbers (no leading '+') permitted to use the assistant."
  type        = list(string)
}

variable "bedrock_model_id" {
  description = "Bedrock foundation model ID used by the agent."
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}
