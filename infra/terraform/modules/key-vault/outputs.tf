output "id" {
  description = "Key Vault resource id."
  value       = azurerm_key_vault.this.id
}

output "name" {
  description = "Key Vault name."
  value       = azurerm_key_vault.this.name
}

output "uri" {
  description = "Vault URI. Resolves to the private endpoint address from inside the VNet, and to nothing useful from outside it."
  value       = azurerm_key_vault.this.vault_uri
}

output "private_endpoint_ip" {
  description = "Private IP assigned to the vault's endpoint NIC. Useful when debugging DNS: compare this with what the client actually resolved."
  value       = azurerm_private_endpoint.this.private_service_connection[0].private_ip_address
}
