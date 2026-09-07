variable "name" {
  description = "Workspace name from the naming module."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group for the workspace object."
  type        = string
}

variable "managed_resource_group_name" {
  description = "Name for the Databricks-managed resource group. Databricks creates and owns everything inside it; never modify its contents by hand."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tags" {
  description = "Standard tag set."
  type        = map(string)
}

variable "sku" {
  description = "standard, premium or trial. Unity Catalog, cluster policies, Entra passthrough, IP access lists and audit logs are ALL premium-only — which makes premium the only viable tier for a governed platform."
  type        = string
  default     = "premium"

  validation {
    condition     = contains(["standard", "premium", "trial"], var.sku)
    error_message = "sku must be standard, premium or trial."
  }
}

variable "virtual_network_id" {
  description = "Spoke VNet to inject the workspace into."
  type        = string
}

variable "host_subnet_name" {
  description = "Name of the delegated host (private) subnet."
  type        = string
}

variable "container_subnet_name" {
  description = "Name of the delegated container (public) subnet. 'Public' is Databricks' terminology and is misleading: with no_public_ip enabled it has no public addressing at all."
  type        = string
}

variable "host_subnet_nsg_association_id" {
  description = "Resource id of the host subnet's NSG association. Databricks requires the association id, not the NSG id."
  type        = string
}

variable "container_subnet_nsg_association_id" {
  description = "Resource id of the container subnet's NSG association."
  type        = string
}

variable "lakehouse_storage_account_id" {
  description = "ADLS Gen2 account the Unity Catalog access connector is granted access to."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Workspace receiving Databricks diagnostics."
  type        = string
  default     = ""
}
