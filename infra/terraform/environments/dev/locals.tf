# ---------------------------------------------------------------------------
# DEVELOPMENT.
#
# Dev is NOT a smaller copy of production. It is a deliberate set of trades,
# and knowing which trades were made is what stops "it worked in dev" from
# being a surprise.
#
#   Kept identical to prod (fidelity matters here):
#     * Private endpoints and public_network_access_enabled = false
#     * Workload identity federation — no secrets anywhere
#     * Azure RBAC on AKS, local account disabled
#     * Network topology shape: hub, spoke, peering, NSGs, subnet layout
#     * Naming and tagging
#
#   Traded away (cost dominates, and the difference is understood):
#     * Second region          — no cross-region failover to test
#     * Azure Firewall         — ~$950/month/region idle. NSGs still apply,
#                                but the egress ALLOW-LIST is not enforced,
#                                so a dependency dev never noticed can break
#                                in stage. This is the sharpest trade here.
#     * Front Door + WAF       — no edge, so WAF false positives surface later
#     * Cosmos multi-region    — serverless, single region
#     * AKS Standard tier      — Free tier, no control-plane SLA
#     * GZRS storage           — LRS
#     * Zone redundancy        — single zone
#     * Alert rules            — billed per rule; dev does not page
#
# docs/architecture/08-cost-and-finops.md carries the arithmetic.
# ---------------------------------------------------------------------------

locals {
  environment = "dev"

  regions = {
    primary = {
      location   = "eastus2"
      hub_cidr   = "10.40.0.0/20"
      spoke_cidr = "10.41.0.0/16"
      priority   = 0
    }
  }

  primary_location = local.regions.primary.location

  # Lower than prod, and stated rather than assumed. Dev has no SLO in any
  # meaningful sense; the value exists so the observability module has a
  # threshold to compute against.
  slo_target = 0.99

  common_tags = {
    platform    = "purple"
    provisioned = "terraform"
    repository  = "azure-data-ai-platform"
    # The tag an automated shutdown policy keys off. In a funded environment
    # a nightly job scales dev node pools to zero on this tag alone, which is
    # typically a 60-70% saving on dev compute.
    auto_shutdown = "true"
  }
}
