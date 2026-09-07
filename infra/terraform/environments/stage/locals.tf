# ---------------------------------------------------------------------------
# STAGING.
#
# Stage exists to close the gaps dev leaves open. Its job is not to be cheap
# and not to be production — it is to be the environment where the things dev
# cannot test are tested, before they are tested by users.
#
# What stage has that dev does NOT, and why each one earns its cost:
#
#   Azure Firewall     The egress allow-list is enforced. A workload that
#                      depends on an un-approved FQDN fails HERE, in a
#                      pipeline, rather than in production at 2am.
#   Front Door + WAF   WAF false positives are found against realistic
#                      traffic. This is the single most common cause of a
#                      "successful" deployment that immediately blocks users.
#   Provisioned Cosmos Autoscale behaviour, RU consumption per operation, and
#                      429 handling are all observable. Serverless shows none
#                      of it.
#   AKS Standard tier  Control-plane behaviour under load matches production.
#   Zone redundancy    Zone failure can be simulated during a game day.
#
# What stage still does NOT have:
#
#   A second region. Cross-region failover is therefore validated by game day
#   in production (docs/runbooks/06-regional-failover-game-day.md), not in
#   stage. Duplicating the whole platform a third time is not justifiable, and
#   pretending single-region stage proves multi-region behaviour is worse than
#   admitting it does not.
# ---------------------------------------------------------------------------

locals {
  environment = "stage"

  regions = {
    primary = {
      location   = "eastus2"
      hub_cidr   = "10.30.0.0/20"
      spoke_cidr = "10.31.0.0/16"
      priority   = 0
    }
  }

  primary_location = local.regions.primary.location

  # Same SLO target as production, deliberately. Stage is where the alerting
  # thresholds themselves are validated: if the burn-rate alerts are too noisy
  # or too quiet, that is discovered here.
  slo_target = 0.9995

  common_tags = {
    platform    = "purple"
    provisioned = "terraform"
    repository  = "azure-data-ai-platform"
  }
}
