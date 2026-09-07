output "id" {
  description = "Registry resource id. Needed to grant AcrPull to an AKS kubelet identity."
  value       = azurerm_container_registry.this.id
}

output "name" {
  description = "Registry name."
  value       = azurerm_container_registry.this.name
}

output "login_server" {
  description = "Registry login server, e.g. purpleplatprodeus2acr.azurecr.io. This is the image prefix used in every Kubernetes manifest."
  value       = azurerm_container_registry.this.login_server
}

output "identity_principal_id" {
  description = "Principal id of the registry's own system-assigned identity."
  value       = azurerm_container_registry.this.identity[0].principal_id
}
