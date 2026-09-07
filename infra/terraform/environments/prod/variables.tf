variable "subscription_id" {
  description = "Target subscription id. Placeholder in this repository."
  type        = string
  default     = "00000000-0000-0000-0000-000000000000"
}

variable "tenant_id" {
  description = "Entra tenant id. Placeholder in this repository."
  type        = string
  default     = "00000000-0000-0000-0000-000000000000"
}

variable "platform_admin_group_object_ids" {
  description = "Entra group object ids granted AKS cluster-admin. Groups, never individuals."
  type        = list(string)
  default     = ["00000000-0000-0000-0000-000000000000"]
}

variable "alert_email_receivers" {
  description = "Where alerts go. Documentation addresses in this repository."
  type        = list(string)
  default     = ["platform-oncall@example.com"]
}

variable "custom_domain" {
  description = "Public API hostname. RFC 2606 documentation domain in this repository."
  type        = string
  default     = "api.purple.example.com"
}

variable "cost_center" {
  description = "Finance cost centre for chargeback."
  type        = string
  default     = "CC-0000-PLATFORM"
}
