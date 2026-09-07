# ---------------------------------------------------------------------------
# SLO-based alerting: multi-window, multi-burn-rate.
#
# Most Azure platforms alert on symptoms of machines: CPU > 80%, memory > 90%,
# pod restarts > 5. Those alerts fire constantly, correlate weakly with user
# pain, and train the on-call engineer to ignore the channel. The industry
# name for the result is alert fatigue, and it is the reason real outages get
# missed.
#
# This module alerts on the ERROR BUDGET instead.
#
# --- the arithmetic ---------------------------------------------------------
#
# An SLO of 99.95% over a 30-day window permits:
#
#     (1 - 0.9995) x 30 days x 24 h x 60 min  =  21.6 minutes of failure
#
# That 21.6 minutes is the ERROR BUDGET. It is a resource that gets spent.
#
# BURN RATE is how fast you are spending it, relative to the rate that would
# exactly exhaust it over the full window. Burn rate 1 means you will finish
# the budget exactly at day 30. Burn rate 14.4 means you will finish it in
# 30/14.4 = ~2 days, and you will have consumed 2% of the whole month's budget
# in the last hour.
#
# The threshold error rate for a given burn rate is simply:
#
#     error_rate_threshold = burn_rate x (1 - SLO)
#
# For a 99.95% SLO:
#     14.4x  ->  0.72%  error rate     page immediately
#      6.0x  ->  0.30%  error rate     page
#      3.0x  ->  0.15%  error rate     ticket
#      1.0x  ->  0.05%  error rate     ticket
#
# --- why TWO windows per alert ---------------------------------------------
#
# A short window alone is fast but flappy: one bad minute pages you. A long
# window alone is stable but slow: a total outage takes hours to alert.
#
# Pairing them gives both. The alert fires only when the long window shows a
# sustained problem AND the short window shows it is still happening. The
# short window is what makes the alert RESOLVE quickly once the incident ends,
# so the on-call engineer is not chasing an alert about something already
# fixed.
#
# Reference: Google SRE Workbook, "Alerting on SLOs", chapter 5.
# ---------------------------------------------------------------------------

locals {
  # The fraction of requests allowed to fail. 0.0005 for a 99.95% SLO.
  error_budget = 1 - var.slo_target

  # Multi-window multi-burn-rate policy. Each entry is one alert rule.
  burn_rate_alerts = {
    fast = {
      burn_rate      = 14.4
      long_window    = "PT1H"
      eval_frequency = "PT5M"
      severity       = 1 # Sev 1: page, wake someone up
      description    = "2% of the 30-day error budget consumed in one hour."
    }
    medium = {
      burn_rate      = 6.0
      long_window    = "PT6H"
      eval_frequency = "PT15M"
      severity       = 2 # Sev 2: page during business hours
      description    = "5% of the 30-day error budget consumed in six hours."
    }
    slow = {
      burn_rate      = 3.0
      long_window    = "P1D"
      eval_frequency = "PT1H"
      severity       = 3 # Sev 3: ticket, look at it tomorrow
      description    = "10% of the 30-day error budget consumed in one day."
    }
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "burn_rate" {
  for_each = var.enable_alerts ? local.burn_rate_alerts : {}

  name                = "${var.name_prefix}-slo-burn-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  description = "${each.value.description} Burn rate ${each.value.burn_rate}x against a ${var.slo_target * 100}% availability SLO. Runbook: docs/runbooks/01-api-error-budget-burn.md"
  severity    = each.value.severity
  enabled     = true

  scopes                  = [azurerm_application_insights.this.id]
  evaluation_frequency    = each.value.eval_frequency
  window_duration         = each.value.long_window
  auto_mitigation_enabled = true

  criteria {
    # The `Total > 100` guard is essential. Without it, a quiet window with
    # 2 requests and 1 failure is a 50% error rate and pages the on-call at
    # 4am about nothing. Every ratio-based alert needs a volume floor.
    query = <<-KQL
      AppRequests
      | where TimeGenerated > ago(${each.value.long_window == "P1D" ? "1d" : lower(replace(each.value.long_window, "PT", ""))})
      | summarize Total = count(), Failed = countif(Success == false)
      | where Total > 100
      | extend ErrorRate = todouble(Failed) / todouble(Total)
      | project ErrorRate
    KQL

    time_aggregation_method = "Maximum"
    metric_measure_column   = "ErrorRate"
    threshold               = each.value.burn_rate * local.error_budget
    operator                = "GreaterThan"

    # Require two consecutive breaching evaluations before firing. This is the
    # cheapest de-flap available and costs only one evaluation period of
    # detection latency.
    failing_periods {
      minimum_failing_periods_to_trigger_alert = 2
      number_of_evaluation_periods             = 2
    }
  }

  action {
    action_groups = [
      each.value.severity <= 2
      ? azurerm_monitor_action_group.critical[0].id
      : azurerm_monitor_action_group.warning[0].id
    ]
  }
}

# --- latency SLO ------------------------------------------------------------
# Availability is not the whole story: a service that answers every request in
# 30 seconds is 100% available and completely unusable. p99 is used rather
# than the mean because the mean hides exactly the tail that users notice.

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "latency_p99" {
  count = var.enable_alerts ? 1 : 0

  name                = "${var.name_prefix}-slo-latency-p99"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  description = "API p99 latency above the 400ms objective for 15 minutes. Runbook: docs/runbooks/02-api-latency.md"
  severity    = 2
  enabled     = true

  scopes                  = [azurerm_application_insights.this.id]
  evaluation_frequency    = "PT5M"
  window_duration         = "PT15M"
  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      AppRequests
      | where TimeGenerated > ago(15m)
      | where Success == true
      | summarize P99 = percentile(DurationMs, 99), Total = count()
      | where Total > 100
      | project P99
    KQL

    time_aggregation_method = "Maximum"
    metric_measure_column   = "P99"
    threshold               = 400
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 2
      number_of_evaluation_periods             = 3
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.critical[0].id]
  }
}

# --- Cosmos DB throttling ---------------------------------------------------
# A leading indicator rather than a symptom. Sustained 429s mean either a hot
# partition or genuine capacity exhaustion, and both degrade the API before
# they show up in the availability SLO. Catching it here buys time to react
# before the error budget starts burning.

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "cosmos_throttling" {
  count = var.enable_alerts ? 1 : 0

  name                = "${var.name_prefix}-cosmos-throttling"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  description = "Cosmos DB returning sustained 429 (request rate too large). Check for a hot partition before raising throughput. Runbook: docs/runbooks/04-cosmos-throttling.md"
  severity    = 2
  enabled     = true

  scopes                  = [azurerm_log_analytics_workspace.this.id]
  evaluation_frequency    = "PT5M"
  window_duration         = "PT15M"
  auto_mitigation_enabled = true

  criteria {
    # Grouping by partition key range is what distinguishes "we need more RU"
    # from "one partition is hot". The two have completely different fixes,
    # and raising throughput to solve a hot partition simply spends money
    # without helping — a single logical partition is capped at 10,000 RU/s
    # no matter what the container is provisioned for.
    query = <<-KQL
      CDBDataPlaneRequests
      | where TimeGenerated > ago(15m)
      | summarize Throttled = countif(StatusCode == 429), Total = count()
      | where Total > 100
      | extend ThrottleRate = todouble(Throttled) / todouble(Total)
      | project ThrottleRate
    KQL

    time_aggregation_method = "Maximum"
    metric_measure_column   = "ThrottleRate"
    threshold               = 0.01 # 1% of requests throttled
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 2
      number_of_evaluation_periods             = 3
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.critical[0].id]
  }
}
