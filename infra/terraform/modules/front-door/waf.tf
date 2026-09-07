# ---------------------------------------------------------------------------
# Web Application Firewall.
#
# Two managed rule sets plus a rate limit. The managed sets are maintained by
# Microsoft and updated as new attack patterns appear, which is the argument
# for using them over hand-written rules: a custom rule set is a snapshot of
# what one team knew on one day.
#
# --- on Detection vs Prevention --------------------------------------------
#
# The default here is Prevention because this is a greenfield design and the
# application is written to the rules. On an EXISTING application, going
# straight to Prevention is a self-inflicted outage: the OWASP set has real
# false-positive rates against applications that put JSON, base64 or SQL-like
# strings in query parameters.
#
# The correct rollout is: Detection -> observe FrontDoorWebApplicationFirewallLog
# for two weeks -> add exclusions for the rules that matched legitimate
# traffic -> Prevention. That sequence is a runbook, not a setting.
# ---------------------------------------------------------------------------

resource "azurerm_cdn_frontdoor_firewall_policy" "this" {
  name                = replace("${var.name}waf", "-", "")
  resource_group_name = var.resource_group_name
  sku_name            = azurerm_cdn_frontdoor_profile.this.sku_name
  enabled             = true
  mode                = var.waf_mode
  tags                = var.tags

  # What a blocked caller sees. A generic page with a reference id: enough for
  # a legitimate user to raise a support ticket, not enough for an attacker to
  # learn which rule fired.
  custom_block_response_status_code = 403
  custom_block_response_body = base64encode(
    "{\"error\":\"request_blocked\",\"message\":\"This request was blocked by a security policy. If you believe this is an error, contact support with the tracking reference from your response headers.\"}"
  )

  # --- rate limiting --------------------------------------------------------
  # Custom rules are evaluated BEFORE managed rules, in priority order, and
  # the first match wins. Rate limiting therefore has to sit here to catch
  # volumetric abuse before it costs managed-rule evaluation.
  custom_rule {
    name     = "RateLimitPerIP"
    enabled  = true
    priority = 100
    type     = "RateLimitRule"
    action   = "Block"

    rate_limit_duration_in_minutes = 1
    rate_limit_threshold           = var.rate_limit_threshold

    match_condition {
      match_variable = "RemoteAddr"
      operator       = "IPMatch"
      match_values   = ["0.0.0.0/0"]
    }
  }

  # A much tighter limit on the authentication endpoint specifically.
  # Credential stuffing is a low-volume-per-IP attack that a global 1000/min
  # limit never notices.
  custom_rule {
    name     = "RateLimitAuthEndpoint"
    enabled  = true
    priority = 90
    type     = "RateLimitRule"
    action   = "Block"

    rate_limit_duration_in_minutes = 1
    rate_limit_threshold           = 20

    match_condition {
      match_variable     = "RequestUri"
      operator           = "Contains"
      match_values       = ["/auth/", "/login", "/token"]
      transforms         = ["Lowercase"]
      negation_condition = false
    }
  }

  # --- managed rule sets ----------------------------------------------------

  managed_rule {
    # The OWASP Core Rule Set: SQL injection, XSS, RCE, path traversal,
    # protocol violations. The single highest-value security control in front
    # of any HTTP service.
    type    = "Microsoft_DefaultRuleSet"
    version = "2.1"
    action  = "Block"

    # Exclusions belong here rather than in a disabled rule. An exclusion
    # narrows a rule to skip one field; disabling the rule removes it for
    # every field, everywhere. The difference is the whole game.
    #
    # Example, left commented because this application does not need it:
    #
    # exclusion {
    #   match_variable = "RequestBodyJsonArgNames"
    #   operator       = "Equals"
    #   selector       = "documentContent"
    # }
  }

  managed_rule {
    # Bot Manager classifies traffic as good (verified search crawlers),
    # bad (known malicious networks) and unknown. Blocking "unknown" outright
    # blocks a lot of legitimate automation, so unknown bots are logged.
    type    = "Microsoft_BotManagerRuleSet"
    version = "1.0"
    action  = "Log"
  }
}

resource "azurerm_cdn_frontdoor_security_policy" "this" {
  name                     = "${var.name}-secpol"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.this.id

      association {
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.this.id
        }
        patterns_to_match = ["/*"]
      }
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.log_analytics_workspace_id != "" ? 1 : 0

  name                           = "to-log-analytics"
  target_resource_id             = azurerm_cdn_frontdoor_profile.this.id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  # The access log is how origin health, failover events and per-region
  # traffic split are actually observed. The WAF log is how false positives
  # are found before they become support tickets.
  enabled_log { category = "FrontDoorAccessLog" }
  enabled_log { category = "FrontDoorHealthProbeLog" }
  enabled_log { category = "FrontDoorWebApplicationFirewallLog" }

  enabled_metric { category = "AllMetrics" }
}
