variable "subscription_id" {
  description = "Target subscription. Placeholder all-zero GUID in this repository; supply a real one via a tfvars file that is never committed."
  type        = string
  default     = "00000000-0000-0000-0000-000000000000"
}

variable "resource_group_name" {
  description = "Resource group holding the state backend."
  type        = string
  default     = "purple-tfstate-rg"
}

variable "storage_account_name" {
  description = "Globally-unique storage account name for state. Must be changed before use: this default will already be taken."
  type        = string
  default     = "purpletfstate000000"

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 lowercase alphanumeric characters."
  }
}

variable "location" {
  description = "Region for the state backend. Should be the platform's primary region: a state backend in a region the platform does not use is an extra failure domain for no benefit."
  type        = string
  default     = "eastus2"
}

variable "owner" {
  description = "Owner tag."
  type        = string
  default     = "platform-team@example.com"
}

variable "state_allowed_ip_ranges" {
  description = "Public IPs or CIDRs permitted to reach the state storage account — the CI runner's egress address, or an operator workstation. Empty by default: the account denies everything until this is set deliberately, because the alternative default is a world-readable state file."
  type        = list(string)
  default     = []
}
