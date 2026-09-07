# ---------------------------------------------------------------------------
# The production topology, in one place.
#
# Everything about "how many regions and where" is expressed here. Adding a
# third region is a change to this map plus a CIDR allocation — not a change
# to any module.
# ---------------------------------------------------------------------------

locals {
  environment = "prod"

  # --- address plan ---------------------------------------------------------
  #
  # The whole platform lives in 10.0.0.0/8, allocated as:
  #
  #   10.10.0.0/20   hub    East US 2       (prod)
  #   10.11.0.0/16   spoke  East US 2       (prod)
  #   10.20.0.0/20   hub    Central US      (prod)
  #   10.21.0.0/16   spoke  Central US      (prod)
  #   10.30.0.0/20   hub    East US 2       (stage)
  #   10.31.0.0/16   spoke  East US 2       (stage)
  #   10.40.0.0/20   hub    East US 2       (dev)
  #   10.41.0.0/16   spoke  East US 2       (dev)
  #
  # Non-overlapping ACROSS environments even though dev and prod never peer.
  # The reason is that they might: a shared-services VNet, an ExpressRoute
  # circuit, or a future migration all require that no two VNets in the estate
  # share address space. Overlapping CIDRs are cheap to avoid now and
  # extremely expensive to fix later, because fixing them means re-addressing
  # a live network.
  regions = {
    primary = {
      location   = "eastus2"
      hub_cidr   = "10.10.0.0/20"
      spoke_cidr = "10.11.0.0/16"
      # Failover priority. 0 is the Cosmos write region.
      priority = 0
    }
    secondary = {
      location   = "centralus"
      hub_cidr   = "10.20.0.0/20"
      spoke_cidr = "10.21.0.0/16"
      priority   = 1
    }
  }

  primary_location   = local.regions.primary.location
  secondary_location = local.regions.secondary.location

  # --- SLO ------------------------------------------------------------------
  # 99.95%, not 99.99%. The reasoning is worked through in
  # docs/architecture/02-availability-model.md: the platform's hard
  # dependencies (AKS control plane, Cosmos, Front Door, Entra) compose to a
  # theoretical ceiling below 99.99%, and committing to a number the
  # architecture cannot deliver is worse than committing to an honest one.
  slo_target = 0.9995

  common_tags = {
    platform    = "purple"
    provisioned = "terraform"
    repository  = "azure-data-ai-platform"
  }
}
