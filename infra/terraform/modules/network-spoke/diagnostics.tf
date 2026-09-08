# ---------------------------------------------------------------------------
# Diagnostic settings.
#
# `local.diagnostics_enabled` and `var.log_analytics_workspace_id` — whose
# description reads "Workspace receiving NSG flow and VNet diagnostics" — both
# existed before this file did, which meant the module accepted a workspace id,
# computed whether diagnostics were on, and then created nothing. Anyone
# passing a workspace would reasonably believe spoke diagnostics were being
# collected. They were not.
#
# The hub has had `diagnostics.tf` from the start. This is its counterpart.
#
# Why it matters here specifically: the spoke is where the workloads run, so
# it is where "pod X cannot reach service Y" is actually diagnosed. NSG rule
# evaluations are the record of what was allowed and what was dropped; without
# them the only way to investigate a blocked flow is to read the rules and
# reason about them, which is exactly the reasoning that produced the bug.
#
# NOTE on scope: these are diagnostic *settings*, not NSG flow logs. Flow logs
# are a separate resource (azurerm_network_watcher_flow_log) requiring a
# Network Watcher and a storage account, neither of which this module owns.
# Adding them means deciding where that storage lives and who retains it —
# a deliberate decision rather than something to slip into a bug fix.
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "spoke_vnet" {
  count = local.diagnostics_enabled ? 1 : 0

  name                       = "to-log-analytics"
  target_resource_id         = azurerm_virtual_network.spoke.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "VMProtectionAlerts" }

  enabled_metric { category = "AllMetrics" }
}

# One per AKS pool NSG. Keyed by the same set the NSGs use, so a new pool
# cannot be added without its diagnostics coming with it.
resource "azurerm_monitor_diagnostic_setting" "aks_nsg" {
  for_each = local.diagnostics_enabled ? azurerm_network_security_group.aks : {}

  name                       = "to-log-analytics"
  target_resource_id         = each.value.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # An NSG emits no metrics — only these two log categories. Requesting
  # AllMetrics here is what makes the apply fail with an unhelpful error.
  enabled_log { category = "NetworkSecurityGroupEvent" }
  enabled_log { category = "NetworkSecurityGroupRuleCounter" }
}

resource "azurerm_monitor_diagnostic_setting" "private_endpoints_nsg" {
  count = local.diagnostics_enabled ? 1 : 0

  name                       = "to-log-analytics"
  target_resource_id         = azurerm_network_security_group.private_endpoints.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "NetworkSecurityGroupEvent" }
  enabled_log { category = "NetworkSecurityGroupRuleCounter" }
}

resource "azurerm_monitor_diagnostic_setting" "databricks_nsg" {
  count = local.diagnostics_enabled && var.enable_databricks_subnets ? 1 : 0

  name                       = "to-log-analytics"
  target_resource_id         = azurerm_network_security_group.databricks[0].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "NetworkSecurityGroupEvent" }
  enabled_log { category = "NetworkSecurityGroupRuleCounter" }
}
