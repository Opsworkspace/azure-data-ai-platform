output "id" {
  description = "Storage account resource id."
  value       = azurerm_storage_account.lakehouse.id
}

output "name" {
  description = "Storage account name."
  value       = azurerm_storage_account.lakehouse.name
}

output "dfs_endpoint" {
  description = "Primary DFS endpoint. The abfss:// scheme used by Spark and Unity Catalog external locations is built from this."
  value       = azurerm_storage_account.lakehouse.primary_dfs_endpoint
}

output "blob_endpoint" {
  description = "Primary blob endpoint."
  value       = azurerm_storage_account.lakehouse.primary_blob_endpoint
}

output "container_names" {
  description = "The medallion containers that were created."
  value       = [for c in azurerm_storage_container.medallion : c.name]
}

output "abfss_paths" {
  description = "Ready-made abfss:// URIs per container, so notebooks and Unity Catalog external locations never hand-assemble a path."
  value = {
    for c in azurerm_storage_container.medallion :
    c.name => "abfss://${c.name}@${azurerm_storage_account.lakehouse.name}.dfs.core.windows.net/"
  }
}
