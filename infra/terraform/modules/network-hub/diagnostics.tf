# ---------------------------------------------------------------------------
# Diagnostic settings.
#
# A firewall whose logs are not collected is a firewall you cannot debug. The
# single most common platform incident is "the application cannot reach X",
# and answering it requires AZFWApplicationRule / AZFWNetworkRule logs.
#
# These use the resource-specific (dedicated table) mode rather than the
# legacy AzureDiagnostics blob, because dedicated tables are typed, cheaper to
# query, and cheaper to ingest.
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "firewall" {
  count = var.deploy_firewall && local.diagnostics_enabled ? 1 : 0

  name                           = "to-log-analytics"
  target_resource_id             = azurerm_firewall.hub[0].id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log { category = "AZFWApplicationRule" }
  enabled_log { category = "AZFWNetworkRule" }
  enabled_log { category = "AZFWDnsQuery" }
  enabled_log { category = "AZFWThreatIntel" }

  enabled_metric { category = "AllMetrics" }
}

resource "azurerm_monitor_diagnostic_setting" "bastion" {
  count = var.deploy_bastion && local.diagnostics_enabled ? 1 : 0

  name                       = "to-log-analytics"
  target_resource_id         = azurerm_bastion_host.hub[0].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # Who connected to which private host, when. This is the audit trail that
  # justifies having removed every public IP.
  enabled_log { category = "BastionAuditLogs" }
}

resource "azurerm_monitor_diagnostic_setting" "hub_vnet" {
  count = local.diagnostics_enabled ? 1 : 0

  name                       = "to-log-analytics"
  target_resource_id         = azurerm_virtual_network.hub.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "VMProtectionAlerts" }

  enabled_metric { category = "AllMetrics" }
}
