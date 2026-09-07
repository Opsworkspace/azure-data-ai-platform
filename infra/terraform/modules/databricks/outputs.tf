output "id" {
  description = "Workspace resource id."
  value       = azurerm_databricks_workspace.this.id
}

output "workspace_url" {
  description = "Workspace URL. The Databricks Terraform provider and CLI authenticate against this host."
  value       = azurerm_databricks_workspace.this.workspace_url
}

output "workspace_id" {
  description = "Numeric Databricks workspace id, used when attaching the workspace to a Unity Catalog metastore."
  value       = azurerm_databricks_workspace.this.workspace_id
}

output "access_connector_id" {
  description = "Access connector resource id. Unity Catalog storage credentials reference this."
  value       = azurerm_databricks_access_connector.unity_catalog.id
}

output "access_connector_principal_id" {
  description = "Principal id of the access connector's managed identity — the only principal with direct data-plane access to the lakehouse."
  value       = azurerm_databricks_access_connector.unity_catalog.identity[0].principal_id
}

output "managed_resource_group_id" {
  description = "The Databricks-owned resource group."
  value       = azurerm_databricks_workspace.this.managed_resource_group_id
}
