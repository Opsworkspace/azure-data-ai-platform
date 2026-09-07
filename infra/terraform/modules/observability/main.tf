# ---------------------------------------------------------------------------
# Observability.
#
# The distinction this module is built around: MONITORING tells you a machine
# is unhealthy; OBSERVABILITY lets you ask a question you did not anticipate.
# The first is a fixed set of dashboards. The second requires that the raw
# telemetry — logs, metrics, traces — is queryable together, after the fact,
# by someone who did not know in advance what they would need.
#
# There are three telemetry systems here and they are not redundant:
#
#   Log Analytics       Logs and KQL. The system of record. Everything else
#                       eventually gets correlated back to this.
#   Application Insights Distributed tracing and application-level telemetry.
#                       Workspace-based, so its data physically lives in the
#                       Log Analytics workspace and can be joined to it.
#   Azure Monitor Workspace  Prometheus metrics from Kubernetes, in the format
#                       the Kubernetes ecosystem already speaks. Kept separate
#                       because Prometheus's data model (labels, high
#                       cardinality, short retention) is genuinely different
#                       from a log store's.
#
# Grafana sits on top of all three. It is the single pane, but it is a VIEW,
# not a storage tier — which is why losing Grafana loses no data.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.name_prefix}-log"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  # PerGB2018 is the current pay-as-you-go tier. Commitment tiers (100 GB/day
  # and up) are ~15-30% cheaper and become worth it above roughly 100 GB/day —
  # a threshold a platform at this scale will cross, so this is a deliberate
  # review point rather than a permanent choice.
  sku               = "PerGB2018"
  retention_in_days = var.log_retention_days
  daily_quota_gb    = var.daily_quota_gb

  # Force queries and ingestion through the workspace's own RBAC rather than
  # letting resource-context permissions leak data across teams.
  local_authentication_enabled = false
  internet_ingestion_enabled   = true
  internet_query_enabled       = true
}

resource "azurerm_application_insights" "this" {
  name                = "${var.name_prefix}-appi"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  application_type = "web"

  # Workspace-based, not classic. Classic App Insights stores data in its own
  # silo where it cannot be joined to infrastructure logs — so the query
  # "show me the pod logs for the trace that produced this 500" is impossible.
  # Classic is retired; any guide that omits this argument predates 2024.
  workspace_id = azurerm_log_analytics_workspace.this.id

  # Sampling. At 2,000 req/s, ingesting every trace is both unaffordable and
  # unhelpful. Adaptive sampling keeps statistically representative traces and
  # preserves exact counts via itemCount, so metrics stay accurate even though
  # individual traces are dropped.
  sampling_percentage = 100 # adaptive sampling is configured in the SDK instead

  local_authentication_enabled = false
}

# --- Prometheus and Grafana -------------------------------------------------

resource "azurerm_monitor_workspace" "prometheus" {
  count = var.deploy_prometheus_and_grafana ? 1 : 0

  name                = "${var.name_prefix}-amw"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_dashboard_grafana" "this" {
  count = var.deploy_prometheus_and_grafana ? 1 : 0

  name                = "${var.name_prefix}-graf"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  grafana_major_version             = "11"
  api_key_enabled                   = false
  deterministic_outbound_ip_enabled = true
  public_network_access_enabled     = true

  # Grafana authenticates to the data sources as ITSELF, using a managed
  # identity, rather than storing a key per data source. The Monitoring Reader
  # role assignment that makes this work is granted by the environment
  # composition, not here, because the scope is subscription-wide.
  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.prometheus[0].id
  }
}

# --- alert routing ----------------------------------------------------------

resource "azurerm_monitor_action_group" "critical" {
  count = var.enable_alerts ? 1 : 0

  name                = "${var.name_prefix}-ag-critical"
  resource_group_name = var.resource_group_name
  short_name          = "critical" # max 12 chars, appears in the SMS/email subject
  tags                = var.tags

  dynamic "email_receiver" {
    for_each = var.alert_email_receivers
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  # In a funded environment this is where a PagerDuty/Opsgenie webhook goes.
  # Left as a documented placeholder: email is a notification channel, not a
  # paging channel, and treating it as one is how 3am alerts get missed.
  #
  # webhook_receiver {
  #   name                    = "pagerduty"
  #   service_uri             = var.pagerduty_webhook_url
  #   use_common_alert_schema = true
  # }
}

resource "azurerm_monitor_action_group" "warning" {
  count = var.enable_alerts ? 1 : 0

  name                = "${var.name_prefix}-ag-warning"
  resource_group_name = var.resource_group_name
  short_name          = "warning"
  tags                = var.tags

  dynamic "email_receiver" {
    for_each = var.alert_email_receivers
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}
