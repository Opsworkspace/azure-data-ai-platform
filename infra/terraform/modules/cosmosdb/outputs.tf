output "id" {
  description = "Cosmos DB account resource id."
  value       = azurerm_cosmosdb_account.this.id
}

output "name" {
  description = "Cosmos DB account name."
  value       = azurerm_cosmosdb_account.this.name
}

output "endpoint" {
  description = "Account endpoint URI. The application uses this with DefaultAzureCredential — there is no key to hand out, because local authentication is disabled."
  value       = azurerm_cosmosdb_account.this.endpoint
}

output "database_name" {
  description = "SQL database name."
  value       = azurerm_cosmosdb_sql_database.this.name
}

output "container_names" {
  description = "Containers created, with the partition key each was given."
  value       = { for k, c in azurerm_cosmosdb_sql_container.this : k => c.partition_key_paths[0] }
}

output "write_regions" {
  description = "Regions accepting writes. One entry unless multi-region writes are enabled."
  value       = var.enable_multi_region_writes ? concat([var.location], var.secondary_locations) : [var.location]
}
