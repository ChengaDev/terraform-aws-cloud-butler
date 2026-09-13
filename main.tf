##############################################
# Data sources & locals
##############################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix = var.name
  # aws_bedrockagentcore_harness's harness_name only allows letters, digits,
  # and underscores (no hyphens), so name_prefix's hyphens are sanitized
  # here. var.name's own validation guarantees a letter-first, <=40-char
  # string, which combined with this satisfies the harness_name pattern.
  harness_name = coalesce(var.bedrock_harness_name, replace(local.name_prefix, "-", "_"))

  common_tags = merge(
    {
      "Project"   = "terraform-aws-cloud-butler"
      "ManagedBy" = "terraform"
    },
    var.tags
  )
}

##############################################
# Lambda packaging (no external dependencies,
# so a plain zip of the source file is enough)
##############################################

data "archive_file" "receiver" {
  type        = "zip"
  source_file = "${path.module}/lambda/receiver.py"
  output_path = "${path.module}/.build/receiver.zip"
}

data "archive_file" "processor" {
  type        = "zip"
  source_file = "${path.module}/lambda/processor.py"
  output_path = "${path.module}/.build/processor.zip"
}

##############################################
# SSM Parameter Store (SecureString) — secrets
##############################################

resource "aws_ssm_parameter" "whatsapp_token" {
  name        = "/${local.name_prefix}/whatsapp/token"
  description = "Meta WhatsApp Cloud API permanent access token."
  type        = "SecureString"
  value       = var.whatsapp_token
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "whatsapp_verify_token" {
  name        = "/${local.name_prefix}/whatsapp/verify-token"
  description = "Meta webhook verification token."
  type        = "SecureString"
  value       = var.whatsapp_verify_token
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "whatsapp_phone_number_id" {
  name        = "/${local.name_prefix}/whatsapp/phone-number-id"
  description = "Meta WhatsApp Cloud API phone number ID."
  type        = "SecureString"
  value       = var.whatsapp_phone_number_id
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "whatsapp_app_secret" {
  name        = "/${local.name_prefix}/whatsapp/app-secret"
  description = "Meta App Secret, used to verify the X-Hub-Signature-256 header on incoming webhook POSTs."
  type        = "SecureString"
  value       = var.whatsapp_app_secret
  tags        = local.common_tags
}

##############################################
# CloudWatch Log Groups
##############################################

resource "aws_cloudwatch_log_group" "receiver" {
  count             = var.enable_lambda_logging ? 1 : 0
  name              = "/aws/lambda/${local.name_prefix}-receiver"
  retention_in_days = var.log_retention_in_days
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "processor" {
  count             = var.enable_lambda_logging ? 1 : 0
  name              = "/aws/lambda/${local.name_prefix}-processor"
  retention_in_days = var.log_retention_in_days
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${local.name_prefix}-webhook"
  retention_in_days = var.log_retention_in_days
  tags              = local.common_tags
}

##############################################
# IAM — Lambda execution roles (least privilege)
##############################################

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---- receiver ----

resource "aws_iam_role" "receiver" {
  name               = "${local.name_prefix}-receiver-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "receiver_basic_logs" {
  count      = var.enable_lambda_logging ? 1 : 0
  role       = aws_iam_role.receiver.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# receiver may ONLY invoke processor and read the verify token — nothing else.
data "aws_iam_policy_document" "receiver_permissions" {
  statement {
    sid       = "InvokeProcessor"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.processor.arn]
  }

  statement {
    sid    = "ReadVerifyTokenAndAppSecret"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
    ]
    resources = [
      aws_ssm_parameter.whatsapp_verify_token.arn,
      aws_ssm_parameter.whatsapp_app_secret.arn,
    ]
  }

  statement {
    sid       = "DecryptSsmSecureStrings"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "receiver_permissions" {
  name   = "${local.name_prefix}-receiver-permissions"
  role   = aws_iam_role.receiver.id
  policy = data.aws_iam_policy_document.receiver_permissions.json
}

# ---- processor ----

resource "aws_iam_role" "processor" {
  name               = "${local.name_prefix}-processor-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "processor_basic_logs" {
  count      = var.enable_lambda_logging ? 1 : 0
  role       = aws_iam_role.processor.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# processor may ONLY invoke the Bedrock AgentCore harness and read the two
# secrets it needs.
data "aws_iam_policy_document" "processor_permissions" {
  statement {
    sid    = "InvokeBedrockHarness"
    effect = "Allow"
    # Both actions are independently required, confirmed by two separate
    # real AccessDeniedExceptions on two separate invocation attempts:
    # granting only InvokeAgentRuntime got denied wanting InvokeHarness,
    # and (previously) granting only InvokeHarness got denied wanting
    # InvokeAgentRuntime. A harness invocation is authorized as two
    # sequential internal checks, not one — the error only ever names
    # whichever check is reached first.
    actions = [
      "bedrock-agentcore:InvokeHarness",
      "bedrock-agentcore:InvokeAgentRuntime",
    ]
    resources = [aws_bedrockagentcore_harness.this.arn]
  }

  statement {
    sid    = "ReadWhatsAppSecrets"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
    ]
    resources = [
      aws_ssm_parameter.whatsapp_token.arn,
      aws_ssm_parameter.whatsapp_phone_number_id.arn,
    ]
  }

  statement {
    sid       = "DecryptSsmSecureStrings"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "processor_permissions" {
  name   = "${local.name_prefix}-processor-permissions"
  role   = aws_iam_role.processor.id
  policy = data.aws_iam_policy_document.processor_permissions.json
}

##############################################
# Lambda functions
##############################################

resource "aws_lambda_function" "receiver" {
  function_name    = "${local.name_prefix}-receiver"
  role             = aws_iam_role.receiver.arn
  handler          = "receiver.handler"
  runtime          = "python3.12"
  timeout          = var.receiver_timeout
  memory_size      = var.receiver_memory_size
  filename         = data.archive_file.receiver.output_path
  source_code_hash = data.archive_file.receiver.output_base64sha256

  environment {
    variables = {
      PROCESSOR_FUNCTION_NAME = aws_lambda_function.processor.function_name
      VERIFY_TOKEN_PARAM      = aws_ssm_parameter.whatsapp_verify_token.name
      APP_SECRET_PARAM        = aws_ssm_parameter.whatsapp_app_secret.name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.receiver,
    aws_iam_role_policy_attachment.receiver_basic_logs,
  ]

  tags = local.common_tags
}

resource "aws_lambda_function" "processor" {
  function_name                  = "${local.name_prefix}-processor"
  role                           = aws_iam_role.processor.arn
  handler                        = "processor.handler"
  runtime                        = "python3.12"
  timeout                        = var.processor_timeout
  memory_size                    = var.processor_memory_size
  reserved_concurrent_executions = var.processor_reserved_concurrent_executions
  filename                       = data.archive_file.processor.output_path
  source_code_hash               = data.archive_file.processor.output_base64sha256

  environment {
    variables = {
      BEDROCK_HARNESS_ARN   = aws_bedrockagentcore_harness.this.arn
      WHATSAPP_TOKEN_PARAM  = aws_ssm_parameter.whatsapp_token.name
      PHONE_NUMBER_ID_PARAM = aws_ssm_parameter.whatsapp_phone_number_id.name
      WHATSAPP_API_VERSION  = var.whatsapp_api_version
      ALLOWED_PHONE_NUMBERS = join(",", var.allowed_phone_numbers)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.processor,
    aws_iam_role_policy_attachment.processor_basic_logs,
  ]

  tags = local.common_tags
}

resource "aws_lambda_permission" "apigw_invoke_receiver" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.receiver.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

##############################################
# API Gateway (HTTP API v2)
##############################################

resource "aws_apigatewayv2_api" "this" {
  name          = "${local.name_prefix}-webhook"
  protocol_type = "HTTP"
  description   = "Public webhook endpoint for the Meta WhatsApp Cloud API."
  tags          = local.common_tags
}

resource "aws_apigatewayv2_integration" "receiver" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.receiver.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_webhook" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /webhook"
  target    = "integrations/${aws_apigatewayv2_integration.receiver.id}"
}

resource "aws_apigatewayv2_route" "post_webhook" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /webhook"
  target    = "integrations/${aws_apigatewayv2_integration.receiver.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = var.api_throttling_burst_limit
    throttling_rate_limit  = var.api_throttling_rate_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId               = "$context.requestId"
      sourceIp                = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      httpMethod              = "$context.httpMethod"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      protocol                = "$context.protocol"
      responseLength          = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }

  tags = local.common_tags
}

##############################################
# Bedrock AgentCore
#
# Uses the AgentCore managed harness rather than "Bedrock Agents Classic"
# (aws_bedrockagent_agent/_agent_alias): Classic is closed to any AWS account
# with no prior Bedrock Agents usage as of July 30, 2026, with no exception
# process — see README > Architecture. The harness is the declarative,
# config-based analog AWS recommends instead: a model + a system prompt +
# managed conversation memory, no container/artifact to build.
##############################################

data "aws_iam_policy_document" "bedrock_harness_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    # Scoped to the account only, not a specific resource-type ARN: the
    # harness's execution role is assumed on behalf of several internal
    # AgentCore resource types (the harness itself, its managed runtime, its
    # managed memory), and guessing the wrong one here would silently break
    # AssumeRole rather than just being less strict.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "bedrock_harness" {
  name               = "${local.name_prefix}-bedrock-harness-role"
  assume_role_policy = data.aws_iam_policy_document.bedrock_harness_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "bedrock_harness_permissions" {
  statement {
    sid       = "InvokeModel"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["*"]
  }

  # Managed memory (conversation history) is read and written by the harness
  # itself via bedrock-agentcore calls (ListEvents, CreateEvent,
  # RetrieveMemoryRecords, and others AWS does not document as a fixed,
  # minimal list) — scoped to the service rather than an incomplete action
  # list that would silently break memory continuity in production.
  statement {
    sid       = "AgentCoreMemoryAccess"
    effect    = "Allow"
    actions   = ["bedrock-agentcore:*"]
    resources = ["*"]
  }

  # Anthropic models on Bedrock are delivered through AWS Marketplace under
  # the hood. Without these, InvokeModel fails with an AccessDeniedException
  # naming these two actions specifically, even with Model access already
  # enabled in the Bedrock console.
  statement {
    sid       = "MarketplaceModelSubscription"
    effect    = "Allow"
    actions   = ["aws-marketplace:ViewSubscriptions", "aws-marketplace:Subscribe"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "bedrock_harness_permissions" {
  name   = "${local.name_prefix}-bedrock-harness-permissions"
  role   = aws_iam_role.bedrock_harness.id
  policy = data.aws_iam_policy_document.bedrock_harness_permissions.json
}

resource "aws_bedrockagentcore_harness" "this" {
  harness_name       = local.harness_name
  execution_role_arn = aws_iam_role.bedrock_harness.arn

  model {
    bedrock_model_config {
      # Recent Claude models require a cross-region inference profile ID
      # (the "us." prefix), not the bare on-demand model ID — see the
      # bedrock_model_id variable description.
      model_id = var.bedrock_model_id
    }
  }

  system_prompt {
    text = var.bedrock_agent_instructions
  }

  # actorId (the sender's phone number, set per-invocation in processor.py)
  # scopes memory per user; this controls how long those memory events are
  # retained before expiring.
  memory {
    managed_memory_configuration {
      event_expiry_duration = var.bedrock_memory_retention_days
    }
  }

  tags = local.common_tags

  depends_on = [aws_iam_role_policy.bedrock_harness_permissions]
}
