output "webhook_url" {
  description = "Callback URL to paste into the Meta Developer Portal's WhatsApp webhook configuration."
  value       = module.whatsapp_assistant.webhook_url
}

output "bedrock_harness_id" {
  description = "ID of the deployed Bedrock AgentCore harness."
  value       = module.whatsapp_assistant.bedrock_harness_id
}

output "bedrock_harness_arn" {
  description = "ARN of the deployed Bedrock AgentCore harness."
  value       = module.whatsapp_assistant.bedrock_harness_arn
}
