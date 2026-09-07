output "openai_id" {
  description = "Azure OpenAI account resource id."
  value       = azurerm_cognitive_account.openai.id
}

output "openai_endpoint" {
  description = "OpenAI account endpoint. Resolves to the private endpoint from inside the VNet."
  value       = azurerm_cognitive_account.openai.endpoint
}

output "openai_deployment_names" {
  description = "Deployment names the application references. Application code names the DEPLOYMENT, never the model, so a model upgrade does not touch code."
  value       = { for k, d in azurerm_cognitive_deployment.models : k => d.name }
}

output "search_id" {
  description = "AI Search service resource id."
  value       = azurerm_search_service.this.id
}

output "search_endpoint" {
  description = "AI Search endpoint URL."
  value       = "https://${azurerm_search_service.this.name}.search.windows.net"
}

output "search_identity_principal_id" {
  description = "Search service's managed identity, for granting it read access to the lakehouse when building an indexer."
  value       = azurerm_search_service.this.identity[0].principal_id
}
