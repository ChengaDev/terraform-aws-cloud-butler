# Contributing

Thanks for considering a contribution. This is a small, focused module —
keep changes scoped, and see [AGENTS.md](./AGENTS.md) first if you (or your
AI agent) are looking for the fast version of everything below plus the
project-specific conventions and known trade-offs.

## Getting set up

You need Terraform `>= 1.5.0`, Python `3.12`, the packages in
`tests/requirements.txt` (`pip install -r tests/requirements.txt` — test-only,
never bundled into the deployed Lambda zips), and (optional, for the README
tables and local security scanning) [`terraform-docs`](https://terraform-docs.io/)
and [`checkov`](https://www.checkov.io/). No AWS account is required to
develop or test this module — everything below runs offline.

```bash
git clone <your fork>
cd terraform-aws-cloud-butler
terraform init -backend=false
```

## Before opening a PR

Run all of these from the repo root; CI runs the same checks and will block
on any of them failing.

```bash
# Format
terraform fmt -recursive -check -diff

# Validate the module and the example (two independent configurations)
terraform validate
(cd examples/complete && terraform init -backend=false && terraform validate)

# Lambda handlers (boto3 is a test-only dependency, never bundled into the
# deployed Lambda zips — see tests/requirements.txt)
python3 -m py_compile lambda/receiver.py lambda/processor.py
pip install -r tests/requirements.txt
python3 -m unittest discover -s tests -v

# If you changed any variable, output, or resource: regenerate the README
# tables and commit the result
terraform-docs -c .terraform-docs.yml .
```

Optional but appreciated: `checkov -d .` for a broader security lint. Note
that this module intentionally accepts a handful of checkov findings (no
VPC, no Dead Letter Queue, no code-signing, short log retention, no KMS CMK
on log groups, and no reserved concurrency specifically on `receiver`,
which is deliberately left uncapped — see README) because each would add
real cost or complexity that conflicts with the module's Free-Tier-friendly,
personal-scale design goal — see the README's "Security notes" section
before treating one of those as a
bug to fix. If you have a use case that needs one of them, a variable to
opt in is welcome; forcing it on for everyone is not.

## Adding a new secret/variable

If you add a new Meta credential or other secret:

1. Add it as a `sensitive = true` variable in `variables.tf`.
2. Store it as an `aws_ssm_parameter` `SecureString` in `main.tf` (don't add
   it as a plain Lambda environment variable).
3. Grant only the Lambda role(s) that actually need it `ssm:GetParameter` on
   that specific parameter's ARN — never widen an existing IAM statement's
   resource list to `"*"` or reuse another function's role.
4. Confirm the paired `kms:Decrypt` statement (scoped to
   `kms:ViaService = ssm.<region>.amazonaws.com`) already covers it — it's
   written generically per-role, so a new parameter under an existing role
   doesn't need its own KMS statement, but a new role does.
5. Regenerate the README tables (see above).

## Testing changes to the Lambda handlers

Tests live in `tests/` and mock every AWS call (`boto3.client` is patched
before either module is imported), so they run with no credentials and no
network access. If you change `lambda/processor.py` or `lambda/receiver.py`,
add or update a test in the matching `tests/test_*.py` file rather than only
validating by eye — this codebase has already had a couple of subtle bugs
(a fail-open allow-list check, a batched-message-array assumption) that
straightforward tests catch immediately.

## Commit / PR style

- Keep commits scoped to one logical change.
- Explain *why*, not just *what*, for anything touching IAM policies, the
  webhook signature check, or the allow-list — see AGENTS.md's
  "Security-sensitive areas" list.
- Update `CHANGELOG.md` under `[Unreleased]` for any user-facing change
  (new/changed/removed variable or output, behavior change).
