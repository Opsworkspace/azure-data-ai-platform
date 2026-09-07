## What changed

<!-- One paragraph. What does this pull request do, and why now? -->

## Architectural impact

- [ ] No architectural change
- [ ] Changes an existing decision — **ADR updated / superseded:** `docs/adr/____`
- [ ] Introduces a new decision — **new ADR added:** `docs/adr/____`

## Safety checklist

This repository is public and must never carry real tenancy data.

- [ ] No real subscription, tenant, object, or principal IDs — placeholders only
- [ ] No secrets, connection strings, SAS tokens, or key material
- [ ] No personal email addresses, names, employer names, or client names
- [ ] No `.tfvars`, `.tfstate`, `backend.hcl`, or `kubeconfig` added
- [ ] No pipeline step that authenticates to a cloud or runs `terraform apply`

## Verification

```
make all
```

<!-- Paste the summary, or say which targets were SKIPped for missing tools. -->
