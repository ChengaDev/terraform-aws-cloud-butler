# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, Cursor, Copilot, Gemini
CLI, Aider, Devin, or any other tool that reads this file) working in this
repository. Humans: see [README.md](./README.md) for usage docs and
[CONTRIBUTING.md](./CONTRIBUTING.md) for the contribution workflow.

## What this project is

A reusable Terraform module (`terraform-aws-cloud-butler`) that
deploys a WhatsApp chatbot on AWS Lambda + API Gateway, backed by an Amazon
Bedrock AgentCore harness (not "Bedrock Agents Classic" — see the note
below). Two Lambda functions, in plain Python 3.12 standard library +
`boto3` (no third-party dependencies, no layers, no Docker build — see
`README.md` > Architecture for why). This repo *is* the module; it is not an
application that consumes one.

## Repository layout

```
main.tf, variables.tf, outputs.tf, versions.tf   # the module itself (root)
lambda/receiver.py                               # webhook handshake + async dispatch
lambda/processor.py                              # message handling + Bedrock + WhatsApp reply
tests/                                            # Python unit tests for both lambdas (mocked AWS calls)
examples/complete/                                # a runnable root configuration consuming this module
.terraform-docs.yml                               # config for the generated README reference tables
```

`main.tf`, `variables.tf`, `outputs.tf` at the repo root are a **reusable
module** — never add a `provider` block there, never hardcode a region, and
never reference anything outside `var.*`/`local.*`. Anything that needs a
real provider configuration or real values belongs in `examples/complete/`.

## Build, validate, and test commands

Run these from the repo root unless noted. All must pass before a change is
considered done.

```bash
# Format (root module + examples)
terraform fmt -recursive -check -diff

# Validate the module itself
terraform init -backend=false -input=false
terraform validate

# Validate the example separately (it's an independent root configuration)
cd examples/complete && terraform init -backend=false -input=false && terraform validate && cd ../..

# Byte-compile both Lambda handlers (catches syntax errors without AWS creds)
python3 -m py_compile lambda/receiver.py lambda/processor.py

# Run the Lambda unit tests (all AWS calls are mocked — no credentials needed).
# boto3 itself must be installed for unittest.mock.patch("boto3.client") to
# resolve, even though it's fully mocked and never actually called; it's a
# test-only dependency — the deployed Lambda zips never bundle it (see
# "What this project is" above: boto3 ships built into the Lambda runtime).
pip install -r tests/requirements.txt
python3 -m unittest discover -s tests -v

# Regenerate the README's Requirements/Resources/Inputs/Outputs tables after
# touching any variable, output, or resource (see .terraform-docs.yml)
terraform-docs -c .terraform-docs.yml .
```

There is no live-AWS test suite and none should be added to CI — this module
provisions billable resources (Lambda, API Gateway, Bedrock AgentCore), so
nothing here should ever run `terraform apply` or `terraform plan` against a
real account automatically. If you need to sanity-check a plan by hand, use
placeholder values, e.g.:

```bash
terraform plan -var="whatsapp_token=x" -var="whatsapp_verify_token=x" \
  -var="whatsapp_phone_number_id=x" -var="whatsapp_app_secret=x" \
  -var='allowed_phone_numbers=["15551234567"]'
```

## Conventions specific to this codebase

- **Both Lambda files are self-contained on purpose.** They duplicate a small
  SSM-secret-caching helper rather than sharing a Lambda Layer, because the
  module deliberately packages each function as a plain zip via
  `data "archive_file"` with no build step. Don't "fix" this duplication by
  introducing a shared layer or a Docker-based build — that's a rejected
  trade-off, not an oversight.
- **The phone allow-list must fail closed.** `ALLOWED_PHONE_NUMBERS` empty
  must mean "reject everyone," never "allow everyone" — see the comment at
  the allow-list check in `lambda/processor.py`. If you touch that logic,
  add a test that an empty allow-list still drops messages.
- **Every webhook POST must be authenticated before it does anything.**
  `receiver.py` verifies `X-Hub-Signature-256` (HMAC-SHA256 over the raw
  body, via the Meta App Secret) before invoking `processor`. Don't relax or
  bypass this — a public webhook URL with no signature check lets anyone
  trigger Bedrock invocations by forging a sender.
- **`processor.py` must isolate each message in a batch.** A single webhook
  payload's `messages` array can hold more than one message (Meta can batch
  rapid successive sends). Each is processed in its own try/except so one
  failure can't crash the whole async Lambda invocation — an uncaught
  exception here triggers Lambda's automatic retry, which would re-send
  already-successful replies. See `_handle_one_message` / `handler` in
  `lambda/processor.py`.
- **This module uses Bedrock AgentCore, not "Bedrock Agents Classic"
  (`aws_bedrockagent_agent`/`_agent_alias`), on purpose.** Classic is closed
  to any AWS account with no prior Bedrock Agents usage as of July 30, 2026,
  with no exception process — confirmed by actually hitting the `403` on a
  fresh account, not just reading about it. Do not "simplify" this module
  back to Classic; it would make the module undeployable for most new
  users. See README > Architecture for the full reasoning.
- **`invoke_harness` requires BOTH `bedrock-agentcore:InvokeHarness` AND
  `bedrock-agentcore:InvokeAgentRuntime` granted together**, not either one
  alone. Found the hard way: granting only `InvokeHarness` produced an
  `AccessDeniedException` naming `InvokeAgentRuntime`; granting only
  `InvokeAgentRuntime` then produced a *different*
  `AccessDeniedException` naming `InvokeHarness`. A harness invocation
  authorizes as two sequential internal checks (the call itself, then its
  routing into the managed agent runtime), and each error only ever names
  whichever check is reached first — so a single successful invocation
  after adding one action doesn't mean the fix is complete; both must be
  present. Don't "simplify" `processor_permissions` back to one action.
- **`runtimeSessionId` must be >= 33 characters** (an AWS-enforced
  constraint on the `invoke_harness` API call) — a bare phone number is
  far too short. `processor.py`'s `_session_id_for` hashes the sender
  (SHA-256) to get a deterministic, fixed-length ID; the sender's real
  phone number is passed separately as `actorId`, which has no such length
  constraint and is what actually scopes the harness's managed memory per
  user. Don't collapse these back into one field.
- **Anthropic models on Bedrock need two account-level steps beyond "Model
  access" enabled** (found only by actually invoking the model, not by
  reading Terraform/provider docs): (1) Anthropic's one-time
  "use-case-details" form, submitted once per AWS account via the Bedrock
  console's Model catalog; (2) the invoking IAM role needs
  `aws-marketplace:ViewSubscriptions`/`Subscribe` — this module's
  `bedrock_harness_permissions` policy already grants it, don't remove it
  even though it looks unrelated to Bedrock at first glance. Missing either
  produces its own distinct, explicit error naming the missing piece.
- **Bedrock model lifecycles change.** `bedrock_model_id`'s default has
  already gone EOL once during this module's development. If invocation
  fails with a lifecycle-related error, check the model's status in Bedrock
  console > Model catalog before assuming a code bug. Recent models also
  need a cross-region inference profile ID (`us.` prefix) — the bare
  on-demand ID fails with "on-demand throughput isn't supported."
- **`terraform destroy` immediately followed by `terraform apply` can fail
  on the harness with a naming collision.** Confirmed by actually running
  the full destroy-then-recreate cycle: the harness's own destroy reports
  complete well before its auto-created managed-memory resource finishes
  deleting (that resource sits in a `DELETING` state for roughly another
  minute). Recreating a harness with the same `harness_name` during that
  window fails with `CreateMemory: Memory with name <name> already
  exists`. Not a permanent orphan — it self-resolves by waiting; if you
  hit it, just retry `apply` after a minute or so.
- **Least-privilege IAM is the point, not a formality — except where AWS
  genuinely doesn't document a minimal action list.** `receiver`'s role can
  only invoke `processor` and read the verify-token/app-secret SSM
  parameters; `processor`'s role can only invoke its own AgentCore harness
  and read the WhatsApp token/phone-number-id parameters. The harness's own
  execution role is the one exception, granted `bedrock-agentcore:*` for
  its internal memory operations — see README > Security notes for why. A
  change that widens `receiver`'s or `processor`'s role (a wildcard
  resource, or reusing one role for both functions) needs a strong
  justification in the PR description.
- **Every SSM `SecureString` read needs the paired `kms:Decrypt` statement**
  scoped to `kms:ViaService = ssm.<region>.amazonaws.com` — easy to forget
  when adding a new secret parameter, and the failure mode (AccessDenied at
  runtime) won't show up in `terraform plan`/`validate`.
- **If a user reports "I sent a message and got nothing back, with zero
  errors anywhere,"** the cause is almost never this module's code — it's
  Meta-side webhook configuration. Check, in order: (1) is the Meta app
  published (README setup guide step 8) — an unpublished app silently
  drops all real webhook data, even from its own developers; (2) is the
  app actually subscribed to the WhatsApp Business Account's events
  (step 9) — a WABA can be, and in testing was, subscribed to a
  *different* app by default, so Meta receives the message fine but never
  forwards it, and every log on the AWS side (API Gateway, `receiver`,
  `processor`) stays completely silent with nothing to point at. Confirm
  or fix the latter with a `GET`/`POST` to
  `graph.facebook.com/v21.0/{waba-id}/subscribed_apps` — see the README
  for the exact commands.

## Security-sensitive areas — extra care required

Changes touching any of these need the reasoning spelled out in the PR
description, not just the diff:

- `lambda/receiver.py`'s signature verification (`_has_valid_signature`)
- The `allowed_phone_numbers` variable validation and its enforcement in
  `lambda/processor.py`
- Any IAM policy document in `main.tf`
- SSM parameter definitions and what reads them

## Commit / PR conventions

- Run the full command list above before opening a PR; a PR that fails
  `terraform fmt -check` or `terraform validate` will be asked to fix that
  first.
- Keep the README's generated tables in sync (`terraform-docs -c
  .terraform-docs.yml .`) whenever a variable, output, or resource changes —
  don't hand-edit the content between the `BEGIN_TF_DOCS`/`END_TF_DOCS`
  markers.
- See [CONTRIBUTING.md](./CONTRIBUTING.md) for commit/PR style and the PR
  template.
