# Security Policy

## Supported Versions

Only the latest tagged release is supported with security fixes. There's
no long-term support branch — given this module's scope (a personal-scale
WhatsApp assistant), everyone is expected to track current releases.

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for a suspected security
vulnerability. Instead, use GitHub's private vulnerability reporting:

1. Go to the [Security tab](https://github.com/ChengaDev/terraform-aws-cloud-butler/security) of this repository.
2. Click **Report a vulnerability**.

If that's not available, email **gazit.chen@gmail.com** with details and,
if possible, steps to reproduce.

You should get a response within a few days. This is a personal
open-source project maintained by one person, not a company with a formal
SLA — please be patient, and thank you for reporting responsibly rather
than exploiting or publicly disclosing first.

## Scope

Areas most likely to matter, given what this module actually does — see
[AGENTS.md](./AGENTS.md) > "Security-sensitive areas" for the full list:

- Webhook signature verification (`lambda/receiver.py`)
- The phone number allow-list and its enforcement (`lambda/processor.py`)
- IAM policies in `main.tf`
- Handling of secrets (SSM `SecureString` parameters, Lambda environment variables)

Issues in third-party dependencies (the Terraform providers, AWS services,
Meta's or Anthropic's own platforms) should be reported to those projects
directly, not here — but feel free to flag it here too if it specifically
affects how this module uses them.
