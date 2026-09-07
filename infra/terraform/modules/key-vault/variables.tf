variable "name" {
  description = "Key Vault name from the naming module. Globally unique, max 24 characters."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group to place the vault in."
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

variable "tenant_id" {
  description = "Entra tenant id. Placeholder all-zero GUID in this repository."
  type        = string
}

variable "private_endpoint_subnet_id" {
  description = "Subnet the private endpoint NIC lands in."
  type        = string
}

variable "private_dns_zone_ids" {
  description = "Zone ids for privatelink.vaultcore.azure.net, from the private-dns module."
  type        = list(string)
}

variable "purge_protection_enabled" {
  description = "Purge protection makes a deleted vault unrecoverable-by-deletion for the retention period. It CANNOT be turned off once on, and it prevents `terraform destroy` from freeing the name. True in stage and prod, false in dev — see the comment in main.tf."
  type        = bool
  default     = true
}

variable "soft_delete_retention_days" {
  description = "Days a deleted vault is recoverable. 7 is the minimum, 90 the maximum."
  type        = number
  default     = 90

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "soft_delete_retention_days must be between 7 and 90."
  }
}

variable "log_analytics_workspace_id" {
  description = "Workspace receiving vault audit logs. Empty disables diagnostics."
  type        = string
  default     = ""
}

variable "sku_name" {
  description = "standard or premium. Premium provides HSM-backed keys and is required if any key must be FIPS 140-2 Level 2 validated."
  type        = string
  default     = "standard"
}
