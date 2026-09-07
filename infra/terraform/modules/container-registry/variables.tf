variable "name" {
  description = "Registry name from the naming module: alphanumeric only, globally unique."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group."
  type        = string
}

variable "location" {
  description = "Primary region."
  type        = string
}

variable "tags" {
  description = "Standard tag set."
  type        = map(string)
}

variable "sku" {
  description = "Basic, Standard or Premium. Only Premium supports private endpoints, geo-replication, and content trust — so any registry that must not be public is necessarily Premium."
  type        = string
  default     = "Premium"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku)
    error_message = "sku must be Basic, Standard or Premium."
  }
}

variable "georeplication_locations" {
  description = "Regions to replicate images to. A second region's AKS cluster pulling across the internet from a single-region registry is both slow and a cross-region dependency during exactly the outage you built the second region for."
  type        = list(string)
  default     = []
}

variable "retention_days" {
  description = "Days an untagged manifest is kept before automatic deletion. Untagged manifests are the layers left behind by an overwritten tag; without retention they accumulate forever and are invisible in the portal's repository view."
  type        = number
  default     = 30
}

variable "private_endpoint_subnet_id" {
  description = "Subnet for the private endpoint NIC."
  type        = string
}

variable "private_dns_zone_ids" {
  description = "Zone ids for privatelink.azurecr.io."
  type        = list(string)
}

variable "log_analytics_workspace_id" {
  description = "Workspace receiving registry diagnostics."
  type        = string
  default     = ""
}
