variable "name_prefix" {
  description = "Hyphenated name stem from the naming module."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group."
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

variable "log_retention_days" {
  description = "Days logs stay queryable in the Analytics tier. 30 is the free floor; beyond it you pay per GB per month. Long retention belongs in the cheaper Basic/Archive tiers, not here."
  type        = number
  default     = 30

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "daily_quota_gb" {
  description = "Hard cap on daily ingestion. -1 means unlimited. A cap is a blunt instrument — it drops telemetry once hit, including the telemetry for the incident that caused the spike — but an uncapped workspace is the most common way an Azure bill triples overnight."
  type        = number
  default     = -1
}

variable "deploy_prometheus_and_grafana" {
  description = "Deploy an Azure Monitor Workspace and Managed Grafana. Grafana carries a per-instance monthly cost, so dev shares the production instance instead of running its own."
  type        = bool
  default     = true
}

variable "alert_email_receivers" {
  description = "Email addresses receiving alerts. Placeholder addresses in this repository; in a funded environment these would be a PagerDuty or Opsgenie webhook, because email is not a paging channel."
  type        = list(string)
  default     = ["platform-oncall@example.com"]
}

variable "slo_target" {
  description = "Availability SLO as a fraction, e.g. 0.9995 for 99.95%. Drives the burn-rate alert thresholds — see the arithmetic in alerts.tf."
  type        = number
  default     = 0.9995

  validation {
    condition     = var.slo_target > 0.9 && var.slo_target < 1
    error_message = "slo_target must be between 0.9 and 1 exclusive."
  }
}

variable "enable_alerts" {
  description = "Create alert rules. Alert rules are billed per rule per month; dev does not need paging."
  type        = bool
  default     = true
}
