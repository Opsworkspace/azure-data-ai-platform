# ----------------------------------------------------------------- 11. edge ---

module "front_door" {
  source = "../../modules/front-door"

  name                = module.naming_platform["primary"].front_door_name
  resource_group_name = azurerm_resource_group.shared.name
  tags                = module.naming_platform["primary"].tags

  sku_name = "Premium_AzureFrontDoor"

  # --- active/active ---------------------------------------------------------
  # Both origins at priority 1 with equal weight. Front Door routes each user
  # to the lower-latency healthy origin, so a user in Chicago is served from
  # Central US and a user in Boston from East US 2 — and when one region fails
  # its probe, every user is served by the other within ~60 seconds with no
  # DNS change and no manual action.
  #
  # The alternative, active/passive (priority 1 and 2), keeps the secondary
  # region idle. It is cheaper in data transfer and much more dangerous: an
  # idle region is an untested region, and the first time it takes traffic is
  # during an incident. Active/active means the failover path is exercised
  # continuously by real users.
  origins = {
    eastus2 = {
      # Placeholder hostnames. In a deployed environment these are the FQDNs
      # of each region's ingress controller. The private_link block below is
      # how they are reached with NO public IP at all.
      host_name = "ingress-eastus2.purple.example.com"
      priority  = 1
      weight    = 500

      # Enabling this requires the Private Link Service that the ingress
      # controller creates, which does not exist until the cluster is running
      # and the controller is deployed. That ordering — infrastructure, then
      # platform, then this — is why it is commented rather than wired.
      #
      # private_link = {
      #   location               = "eastus2"
      #   private_link_target_id = <the ingress controller's PLS id>
      # }
    }
    centralus = {
      host_name = "ingress-centralus.purple.example.com"
      priority  = 1
      weight    = 500
    }
  }

  custom_domain = var.custom_domain

  waf_mode             = "Prevention"
  rate_limit_threshold = 1000

  # A DEEP readiness probe, not a static 200. See the long note in
  # modules/front-door/main.tf and services/api/app/health.py.
  health_probe_path = "/healthz/ready"

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}
