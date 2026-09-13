## What does this change and why?

## Checklist

- [ ] `terraform fmt -recursive -check -diff` passes
- [ ] `terraform validate` passes for both the root module and `examples/complete`
- [ ] `python3 -m py_compile lambda/receiver.py lambda/processor.py` passes
- [ ] `python3 -m unittest discover -s tests -v` passes, with a new/updated
      test for any behavior change
- [ ] README tables regenerated (`terraform-docs -c .terraform-docs.yml .`)
      if a variable, output, or resource changed
- [ ] `CHANGELOG.md` updated under `[Unreleased]` if this is user-facing

## Security-sensitive change?

If this touches IAM policies, the webhook signature check
(`lambda/receiver.py`), or the phone allow-list (`lambda/processor.py`),
explain the reasoning here — see `AGENTS.md` > "Security-sensitive areas."
