variable "name" {
  description = "Name prefix applied to every resource created by this module. Must be unique per AWS account/region if you deploy the module more than once."
  type        = string
  default     = "whatsapp-assistant"

  validation {
    # Must start with a letter: aws_bedrockagentcore_harness's harness_name
    # (derived from this, hyphens swapped for underscores — see main.tf)
    # requires a letter-first name, so this is enforced here rather than
    # failing confusingly deep in a resource attribute.
    condition     = can(regex("^[a-z][a-z0-9-]{0,39}$", var.name))
    error_message = "The name must be 1-40 characters long, start with a lowercase letter, and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "whatsapp_token" {
  description = "Permanent access token for the Meta WhatsApp Cloud API, generated for a System User in Meta Business Manager. Stored as a SecureString in SSM Parameter Store, never in plain Terraform state outputs."
  type        = string
  sensitive   = true
}

variable "whatsapp_verify_token" {
  description = "Arbitrary secret string you choose. Meta sends it back during the GET /webhook handshake and this module confirms it matches before returning the challenge. Enter the same value in the Meta Developer Portal's webhook configuration."
  type        = string
  sensitive   = true
}

variable "whatsapp_phone_number_id" {
  description = "Phone number ID of the WhatsApp Business sender, from the Meta Developer Portal > WhatsApp > API Setup page."
  type        = string
  sensitive   = true
}

variable "whatsapp_app_secret" {
  description = "App Secret of the Meta App (Developer Portal > App settings > Basic > App secret). Used to verify the HMAC-SHA256 signature (X-Hub-Signature-256) Meta attaches to every webhook POST, so forged requests to the public webhook URL are rejected before they can trigger a Bedrock invocation or a spoofed reply."
  type        = string
  sensitive   = true
}

variable "whatsapp_api_version" {
  description = "Graph API version used when calling the WhatsApp Cloud API to send replies."
  type        = string
  default     = "v21.0"
}

variable "allowed_phone_numbers" {
  description = "Allow-list of sender phone numbers, in E.164 format without a leading '+' (e.g. [\"15551234567\"]), permitted to use the assistant. Messages from any other number are silently dropped by the processor Lambda."
  type        = list(string)

  validation {
    condition     = length(var.allowed_phone_numbers) > 0
    error_message = "Provide at least one allowed phone number so the assistant is not usable by arbitrary WhatsApp users."
  }

  validation {
    # Guards against e.g. [""] silently satisfying the length check above:
    # processor.py filters blank entries out of ALLOWED_PHONE_NUMBERS, and an
    # allow-list that ends up empty after filtering is treated as "no
    # restriction configured" and lets every sender through.
    condition     = alltrue([for n in var.allowed_phone_numbers : can(regex("^[1-9][0-9]{6,14}$", n))])
    error_message = "Each entry must be digits only, in E.164 format without a leading '+' or '0' (e.g. \"15551234567\"), 7-15 digits long."
  }
}

variable "bedrock_model_id" {
  description = "Bedrock model ID used by the agent. Recent Claude models require a cross-region inference profile ID (the \"us.\" prefix, e.g. \"us.anthropic.claude-haiku-4-5-20251001-v1:0\") rather than the bare on-demand model ID — using the bare ID fails at invocation time with \"on-demand throughput isn't supported.\" The model also needs three one-time account setup steps, done once per AWS account: (1) enable it under Bedrock console > Model access, (2) submit Anthropic's one-time use-case-details form (shown on the model's page in the Bedrock console catalog if not yet done), (3) verify it isn't end-of-life — check Bedrock console > Model catalog for its lifecycle status, since model availability changes over time and an EOL model fails at invocation with a clear error."
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "bedrock_harness_name" {
  description = "Name of the Bedrock AgentCore harness. Must start with a letter and contain only letters, digits, and underscores (AWS's harness naming rule) — defaults to `name` with hyphens replaced by underscores."
  type        = string
  default     = null

  validation {
    condition     = var.bedrock_harness_name == null || can(regex("^[A-Za-z][A-Za-z0-9_]{0,39}$", var.bedrock_harness_name))
    error_message = "Must start with a letter and contain only letters, digits, and underscores, 1-40 characters long."
  }
}

variable "bedrock_agent_instructions" {
  description = "System instructions that define the assistant's personality and response style."
  type        = string
  default     = <<-EOT
    You are a concise, practical personal assistant chatting with the user over WhatsApp.
    Keep replies short and mobile-friendly: prefer a couple of short paragraphs or a brief
    bullet list using a plain "-" for bullets. Never use markdown headers, bold/italic
    asterisks, or code fences, since WhatsApp displays plain text only. Be direct, warm, and
    helpful, get straight to useful information, and ask a brief clarifying question when a
    request is ambiguous instead of guessing.
  EOT
}

variable "bedrock_memory_retention_days" {
  description = "How many days a WhatsApp conversation's memory (keyed by the sender's phone number as the AgentCore actor ID) is retained before it expires. AWS requires a value between 7 and 365."
  type        = number
  default     = 30

  validation {
    condition     = var.bedrock_memory_retention_days >= 7 && var.bedrock_memory_retention_days <= 365
    error_message = "Must be between 7 and 365 days (AWS's own valid range for AgentCore memory event expiry)."
  }
}

variable "receiver_timeout" {
  description = "Timeout, in seconds, for the receiver Lambda function. Kept short since it only verifies the request and fires an asynchronous invocation."
  type        = number
  default     = 10
}

variable "receiver_memory_size" {
  description = "Memory, in MB, allocated to the receiver Lambda function."
  type        = number
  default     = 128
}

variable "processor_timeout" {
  description = "Timeout, in seconds, for the processor Lambda function. Must comfortably exceed the Bedrock AgentCore harness's typical response time."
  type        = number
  default     = 90
}

variable "processor_memory_size" {
  description = "Memory, in MB, allocated to the processor Lambda function."
  type        = number
  default     = 256
}

variable "processor_reserved_concurrent_executions" {
  description = "Maximum number of concurrent processor Lambda invocations. Caps how many simultaneous Bedrock AgentCore calls — and therefore how much cost — a burst of messages can generate, whether from legitimate heavy use, a compromised allowed sender, or Meta redelivering a backlog. Set to -1 to remove the limit and use the account's shared unreserved concurrency pool instead. The default of 5 is generous for a handful of personal users; invocations beyond the cap are throttled, and while Lambda retries asynchronous invocations automatically for a period, a burst that persists longer than that can mean some messages don't get a reply rather than queuing indefinitely."
  type        = number
  default     = 5
}

variable "api_throttling_burst_limit" {
  description = "Maximum burst of concurrent requests the webhook's API Gateway stage accepts before throttling (HTTP 429) the excess. This is the first line of defense in front of receiver, capping request volume before it can turn into Lambda invocations or Bedrock cost downstream. AWS's own account-wide default (in the thousands) applies if this were unset; this module sets an explicit, much lower default suited to personal-scale traffic."
  type        = number
  default     = 20
}

variable "api_throttling_rate_limit" {
  description = "Steady-state requests per second the webhook's API Gateway stage accepts before throttling the excess. See api_throttling_burst_limit for why this has an explicit, low default rather than inheriting AWS's account-wide default."
  type        = number
  default     = 10
}

variable "enable_lambda_logging" {
  description = "Whether to create CloudWatch Log Groups for the receiver and processor Lambda functions and grant them permission to write to CloudWatch Logs. Set to false to opt the two functions out of logging entirely (e.g. to avoid ever writing message-related data to CloudWatch); API Gateway access logging is unaffected by this flag."
  type        = bool
  default     = true
}

variable "log_retention_in_days" {
  description = "CloudWatch Logs retention period, in days, applied to the Lambda and API Gateway log groups. Ignored for the Lambda log groups when enable_lambda_logging is false."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Additional resource tags merged into every resource created by this module."
  type        = map(string)
  default     = {}
}
