# Azure Policy as code

Guard rails that apply to the **subscription**, not to a cluster or a pipeline.

## Why these exist even though Terraform already sets everything correctly

Terraform governs what Terraform creates. Azure Policy governs what *exists*.

The gap between those two is where real incidents live:

- Someone creates a storage account in the portal during an incident.
- A different team deploys into the same subscription with their own IaC.
- A resource is created by an Azure service on your behalf.
- Someone changes a setting by hand and nobody runs `terraform plan` for a week.

Policy is the control that survives all of those, because it is evaluated by
Azure itself at resource-write time and continuously thereafter.

## The three effects, and when each is right

| Effect | What it does | Use it when |
|---|---|---|
| `Audit` | Records non-compliance, changes nothing | Always, first. You cannot fix what you have not measured. |
| `Deny` | Rejects the resource write outright | The rule is absolute and the failure mode is worse than the inconvenience |
| `DeployIfNotExists` | Creates the missing thing automatically | The correct configuration is unambiguous — diagnostic settings, for example |

The rollout order is always Audit → measure → remediate → Deny. A `Deny`
policy assigned to a subscription that already contains non-compliant
resources does not delete them; it blocks the *next* legitimate change to
them, which is how a policy rollout turns into an outage during someone
else's deployment.

## What is here

| File | Enforces |
|---|---|
| `deny-public-ip.json` | No public IP addresses on VMs or node pools |
| `deny-public-network-access.json` | PaaS services must have public network access disabled |
| `require-tags.json` | The six standard tags must be present |
| `audit-diagnostic-settings.json` | Every resource ships logs to Log Analytics |
| `initiative-platform-baseline.json` | Bundles the above into one assignable set |

## How they would be assigned

Not assigned in this repository — assignment requires a real subscription.
The Terraform that would do it:

```hcl
resource "azurerm_subscription_policy_assignment" "baseline" {
  name                 = "purple-platform-baseline"
  subscription_id      = "/subscriptions/${var.subscription_id}"
  policy_definition_id = azurerm_policy_set_definition.baseline.id
  enforce              = true

  non_compliance_message {
    content = "This resource violates the Purple platform baseline. See platform/policies/README.md."
  }
}
```

The `non_compliance_message` is worth more than it looks: without it, a
developer whose deployment is denied gets a generic `RequestDisallowedByPolicy`
error naming a GUID.
