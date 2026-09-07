output "resource_group_name" {
  description = "State resource group name."
  value       = azurerm_resource_group.state.name
}

output "storage_account_name" {
  description = "State storage account name."
  value       = azurerm_storage_account.state.name
}

output "container_name" {
  description = "State blob container name."
  value       = azurerm_storage_container.state.name
}

output "backend_config_hcl" {
  description = "Copy this into infra/terraform/backend.hcl (gitignored), then run `terraform init -backend-config=../../backend.hcl` in each environment."
  value       = <<-EOT
    resource_group_name  = "${azurerm_resource_group.state.name}"
    storage_account_name = "${azurerm_storage_account.state.name}"
    container_name       = "${azurerm_storage_container.state.name}"
    use_azuread_auth     = true
  EOT
}
