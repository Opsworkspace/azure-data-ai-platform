output "resource_group_name" {
  description = "Spoke resource group name."
  value       = azurerm_resource_group.spoke.name
}

output "vnet_id" {
  description = "Spoke VNet resource id."
  value       = azurerm_virtual_network.spoke.id
}

output "vnet_name" {
  description = "Spoke VNet name."
  value       = azurerm_virtual_network.spoke.name
}

output "address_space" {
  description = "Spoke address space."
  value       = var.address_space
}

output "aks_system_subnet_id" {
  description = "Subnet for the AKS system node pool."
  value       = azurerm_subnet.aks_system.id
}

output "aks_user_subnet_id" {
  description = "Subnet for the AKS application node pool."
  value       = azurerm_subnet.aks_user.id
}

output "aks_ai_subnet_id" {
  description = "Subnet for the AKS AI/GPU node pool."
  value       = azurerm_subnet.aks_ai.id
}

output "private_endpoint_subnet_id" {
  description = "Subnet every private endpoint lands in. Passed to every data-plane module."
  value       = azurerm_subnet.private_endpoints.id
}

output "integration_subnet_id" {
  description = "Reserved subnet for future VNet-integrated PaaS compute."
  value       = azurerm_subnet.integration.id
}

output "databricks_host_subnet_id" {
  description = "Delegated Databricks host subnet, or null when Databricks is not deployed here."
  value       = var.enable_databricks_subnets ? azurerm_subnet.databricks_host[0].id : null
}

output "databricks_container_subnet_id" {
  description = "Delegated Databricks container subnet, or null."
  value       = var.enable_databricks_subnets ? azurerm_subnet.databricks_container[0].id : null
}

output "databricks_nsg_id" {
  description = "NSG shared by the Databricks subnet pair. Databricks requires the id at workspace creation."
  value       = var.enable_databricks_subnets ? azurerm_network_security_group.databricks[0].id : null
}

output "subnet_cidrs" {
  description = "Every computed subnet CIDR, for documentation and for writing firewall rules that reference specific tiers."
  value       = local.subnets
}

output "databricks_host_nsg_association_id" {
  description = "Resource id of the host subnet's NSG association. Databricks requires the ASSOCIATION id, not the NSG id — passing the NSG id produces a workspace creation failure that names neither."
  value       = var.enable_databricks_subnets ? azurerm_subnet_network_security_group_association.databricks_host[0].id : null
}

output "databricks_container_nsg_association_id" {
  description = "Resource id of the container subnet's NSG association."
  value       = var.enable_databricks_subnets ? azurerm_subnet_network_security_group_association.databricks_container[0].id : null
}

output "databricks_host_subnet_name" {
  description = "Name of the delegated host subnet, which Databricks takes by name rather than by id."
  value       = var.enable_databricks_subnets ? azurerm_subnet.databricks_host[0].name : null
}

output "databricks_container_subnet_name" {
  description = "Name of the delegated container subnet."
  value       = var.enable_databricks_subnets ? azurerm_subnet.databricks_container[0].name : null
}
