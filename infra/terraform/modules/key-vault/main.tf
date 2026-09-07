# ---------------------------------------------------------------------------
# Key Vault.
#
# Two decisions here are worth more than the rest of the file:
#
# 1. RBAC authorization, not access policies. Access policies are the older
#    model: a per-vault list of principals and verbs, invisible to Azure RBAC,
#    unqueryable by Resource Graph, and impossible to grant through PIM. RBAC
#    mode makes vault permissions ordinary role assignments, which means they
#    inherit every governance tool the platform already has. Access policies
#    are not deprecated, but choosing them in 2026 is choosing to be exempt
#    from your own identity governance.
#
# 2. No secrets are created by Terraform. Writing a secret in Terraform puts
#    its value in state, and state is a file. This module creates the vault
#    and the permissions; values arrive from workloads at runtime, or from an
#    operator, never from a plan. See docs/adr/0007-secrets-handling.md.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

resource "azurerm_key_vault" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = var.tenant_id
  sku_name            = var.sku_name
  tags                = var.tags

  rbac_authorization_enabled = true

  # Soft delete is mandatory and cannot be disabled. Purge protection is
  # optional and is the one that hurts: with it on, `terraform destroy`
  # leaves the vault name reserved for the retention period, so a dev
  # environment that is torn down nightly can never be rebuilt under the same
  # name. Hence: on in stage and prod, off in dev.
  purge_protection_enabled   = var.purge_protection_enabled
  soft_delete_retention_days = var.soft_delete_retention_days

  # Defence in depth. public_network_access_enabled = false closes the door;
  # the network ACL below is the second lock, and matters because a future
  # operator who flips public access back on still lands on a default Deny.
  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
    # AzureServices bypass covers the platform services that cannot use a
    # private endpoint — notably Azure Backup and the Key Vault CSI driver's
    # control-plane calls in some configurations. It does NOT open the vault
    # to the internet.
    bypass = "AzureServices"
  }

  # Deployment integrations, all off. Each one is a bypass of the RBAC model:
  # enabled_for_template_deployment in particular lets any ARM deployment in
  # the subscription read secrets from this vault.
  enabled_for_deployment          = false
  enabled_for_disk_encryption     = false
  enabled_for_template_deployment = false
}

resource "azurerm_private_endpoint" "this" {
  name                = "${var.name}-pe"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.name}-psc"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    # Manual connection requires a human to approve the link on the target.
    # Automatic is correct when both sides are owned by the same team, which
    # they are here.
    is_manual_connection = false
  }

  # This block is what writes the A record into the private DNS zone. Omitting
  # it creates a working private endpoint that nothing can resolve — the
  # single most common private-networking mistake in Azure.
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = var.private_dns_zone_ids
  }
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "to-log-analytics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # Every read of every secret, by every principal. This is the log that
  # answers "was this credential accessed during the incident window", and it
  # is worthless if it is turned on after the incident.
  enabled_log { category = "AuditEvent" }
  enabled_log { category = "AzurePolicyEvaluationDetails" }

  enabled_metric { category = "AllMetrics" }
}
