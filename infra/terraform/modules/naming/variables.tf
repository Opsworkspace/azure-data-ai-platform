variable "prefix" {
  description = "Platform-wide prefix. Short, lowercase, no hyphens — it appears in globally-unique names where hyphens are illegal."
  type        = string
  default     = "purple"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,7}$", var.prefix))
    error_message = "prefix must be 3-8 lowercase alphanumeric characters and start with a letter."
  }
}

variable "workload" {
  description = "The capability this resource group belongs to: plat (shared platform), data (lakehouse and analytics), or app (product services)."
  type        = string

  validation {
    condition     = contains(["plat", "data", "app", "net", "sec"], var.workload)
    error_message = "workload must be one of: plat, data, app, net, sec."
  }
}

variable "environment" {
  description = "Deployment environment."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be one of: dev, stage, prod."
  }
}

variable "location" {
  description = "Azure region, in the short lowercase form (e.g. eastus2)."
  type        = string
}

variable "instance" {
  description = "Instance discriminator, for the rare case where two identical resources coexist in one scope. Empty means no discriminator."
  type        = string
  default     = ""
}

variable "owner" {
  description = "Team accountable for the resource. Becomes the owner tag and is used to route alerts."
  type        = string
  default     = "platform-team@example.com"
}

variable "cost_center" {
  description = "Finance cost centre code for chargeback."
  type        = string
  default     = "CC-0000-PLATFORM"
}

variable "data_classification" {
  description = "Highest classification of data the resource may hold. Drives which Azure Policy initiatives apply."
  type        = string
  default     = "internal"

  validation {
    condition     = contains(["public", "internal", "confidential", "restricted"], var.data_classification)
    error_message = "data_classification must be one of: public, internal, confidential, restricted."
  }
}

variable "uniqueness_seed" {
  description = "Seed for the deterministic global-uniqueness suffix. In practice the subscription id, so the same code in two subscriptions yields different global names. A placeholder GUID is fine — it only has to be stable."
  type        = string
  default     = "00000000-0000-0000-0000-000000000000"
}

variable "extra_tags" {
  description = "Additional tags merged over the standard set. Use sparingly: a tag that is not queried is a tag that is not maintained."
  type        = map(string)
  default     = {}
}
