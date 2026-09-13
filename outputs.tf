output "webhook_url" {
  description = "Public HTTPS webhook URL to configure as the Callback URL in the Meta Developer Portal (WhatsApp > Configuration)."
  value       = "${aws_apigatewayv2_api.this.api_endpoint}/webhook"
}

output "bedrock_harness_id" {
  description = "ID of the Bedrock AgentCore harness backing the assistant."
  value       = aws_bedrockagentcore_harness.this.harness_id
}

output "bedrock_harness_arn" {
  description = "ARN of the Bedrock AgentCore harness that the processor Lambda invokes."
  value       = aws_bedrockagentcore_harness.this.arn
}

output "api_gateway_id" {
  description = "ID of the HTTP API Gateway fronting the webhook."
  value       = aws_apigatewayv2_api.this.id
}

output "api_gateway_endpoint" {
  description = "Base invoke URL of the HTTP API Gateway, without the /webhook path."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "receiver_lambda_function_name" {
  description = "Name of the receiver Lambda function."
  value       = aws_lambda_function.receiver.function_name
}

output "receiver_lambda_function_arn" {
  description = "ARN of the receiver Lambda function."
  value       = aws_lambda_function.receiver.arn
}

output "processor_lambda_function_name" {
  description = "Name of the processor Lambda function."
  value       = aws_lambda_function.processor.function_name
}

output "processor_lambda_function_arn" {
  description = "ARN of the processor Lambda function."
  value       = aws_lambda_function.processor.arn
}

output "ssm_parameter_names" {
  description = "Names of the SSM SecureString parameters created for the Meta credentials."
  value = {
    whatsapp_token           = aws_ssm_parameter.whatsapp_token.name
    whatsapp_verify_token    = aws_ssm_parameter.whatsapp_verify_token.name
    whatsapp_phone_number_id = aws_ssm_parameter.whatsapp_phone_number_id.name
    whatsapp_app_secret      = aws_ssm_parameter.whatsapp_app_secret.name
  }
}
