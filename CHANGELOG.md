# Changelog

All notable changes to this module are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versioning
follows [Semantic Versioning](https://semver.org/).

## [1.0.0]

Initial public release. Deployed and confirmed working end to end against
a real AWS account and a real WhatsApp conversation — including a full
`terraform destroy` → `apply` cycle — before being tagged.

### Added

- Decoupled async `receiver`/`processor` Lambda pattern behind an HTTP API
  v2 webhook, so Meta never sees a slow response or retries a delivery
  while the assistant is generating a reply.
- Amazon Bedrock AgentCore integration (a managed harness: model + system
  prompt + per-user managed conversation memory), chosen over "Bedrock
  Agents Classic" because Classic is closed to any AWS account with no
  prior usage as of July 30, 2026, with no exception process — see
  README > Architecture.
- Every webhook POST authenticated via `X-Hub-Signature-256`
  (HMAC-SHA256, constant-time comparison) before it can trigger a model
  invocation or reach `processor` at all.
- A phone-number allow-list, enforced fail-closed (an empty or malformed
  list drops every sender, never allows everyone).
- Every text message in a batched webhook payload processed and isolated
  independently, so one failure can't block or duplicate the others.
- Cost/abuse bounded by default: `processor_reserved_concurrent_executions`
  and API Gateway request throttling, both configurable.
- Least-privilege IAM per Lambda role; secrets in SSM `SecureString`
  parameters, never in plain environment variables or Terraform state
  outputs.
- Zero third-party Python dependencies in either deployed Lambda —
  `boto3` and the standard library only, packaged as a plain zip with no
  build step, no layer, no Docker image.
- A runnable example (`examples/complete`) and a full unit test suite for
  both Lambda handlers (`tests/`, all AWS calls mocked).
- `AGENTS.md` / `CLAUDE.md` for AI coding agents working on this repo;
  `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, issue/PR
  templates, and CI (GitHub Actions) running `terraform fmt`/`validate`,
  a `terraform-docs` drift check, and the Python test suite.

### Notes on things that only show up with real usage

- Recent Claude models require a cross-region inference profile ID (the
  `us.` prefix) rather than a bare on-demand model ID, and model
  lifecycles change over time — check Bedrock's Model catalog if
  invocation fails with a lifecycle-related error.
- Anthropic models on Bedrock need two account-level steps beyond
  enabling Model access: Anthropic's one-time use-case-details form, and
  AWS Marketplace subscription permissions on the invoking role (this
  module's IAM policy already grants the latter).
- After a Meta app is set up, two more one-time steps are required before
  it receives any real webhook traffic at all: the app must be
  **published** (an unpublished app silently drops all real data, even
  from its own developers), and it must be **subscribed to the WhatsApp
  Business Account's webhook events** via `POST /{waba-id}/subscribed_apps`
  — a WABA can default to being subscribed to a different app entirely,
  in which case Meta receives messages fine but never forwards them, with
  no error anywhere to point at. Both are documented in the README's
  setup guide.
- `terraform destroy` works cleanly, but immediately recreating a harness
  with the same name can hit a transient `CreateMemory: Memory with name
  <name> already exists` error — the harness's managed-memory resource
  takes about a minute longer to finish deleting than the harness itself
  reports. Self-resolves by waiting and retrying `apply`.
