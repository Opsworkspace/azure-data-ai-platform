output "log_analytics_workspace_id" {
  description = "Workspace resource id. Passed to every module that emits diagnostics."
  value       = azurerm_log_analytics_workspace.this.id
}

output "log_analytics_workspace_name" {
  description = "Workspace name."
  value       = azurerm_log_analytics_workspace.this.name
}

output "log_analytics_customer_id" {
  description = "Workspace GUID, used by agents that predate resource-id-based configuration."
  value       = azurerm_log_analytics_workspace.this.workspace_id
}

output "application_insights_id" {
  description = "Application Insights resource id."
  value       = azurerm_application_insights.this.id
}

output "application_insights_connection_string" {
  description = "Connection string for the OpenTelemetry exporter. Marked sensitive because it embeds the ingestion key — the application reads it from Key Vault via the CSI driver, never from a manifest."
  value       = azurerm_application_insights.this.connection_string
  sensitive   = true
}

output "prometheus_workspace_id" {
  description = "Azure Monitor workspace id for managed Prometheus, or null."
  value       = var.deploy_prometheus_and_grafana ? azurerm_monitor_workspace.prometheus[0].id : null
}

output "prometheus_query_endpoint" {
  description = "PromQL query endpoint, for Grafana and for kubectl-based debugging."
  value       = var.deploy_prometheus_and_grafana ? azurerm_monitor_workspace.prometheus[0].query_endpoint : null
}

output "grafana_endpoint" {
  description = "Grafana URL."
  value       = var.deploy_prometheus_and_grafana ? azurerm_dashboard_grafana.this[0].endpoint : null
}

output "grafana_identity_principal_id" {
  description = "Grafana's managed identity. Needs Monitoring Reader at subscription scope to query Azure Monitor as a data source."
  value       = var.deploy_prometheus_and_grafana ? azurerm_dashboard_grafana.this[0].identity[0].principal_id : null
}

output "action_group_critical_id" {
  description = "Action group for paging severities."
  value       = var.enable_alerts ? azurerm_monitor_action_group.critical[0].id : null
}

output "error_budget_minutes_per_month" {
  description = "Minutes of downtime the SLO permits per 30-day window. Computed so the number in dashboards and the number in Terraform can never disagree."
  value       = (1 - var.slo_target) * 30 * 24 * 60
}
