# ---------------------------------------------------------------------------
# Azure Firewall — the single egress point for the region.
#
# The design rule this enforces: no workload subnet has a default route to the
# internet. Every spoke's route table sends 0.0.0.0/0 to this firewall's
# private IP, so all outbound traffic is inspected, logged, and matched
# against an allow-list that lives in version control.
#
# This is the most expensive single resource in the platform. It is billed per
# deployment-hour plus per GB processed, in each region, whether traffic flows
# or not. `deploy_firewall = false` is therefore the correct setting for dev,
# and the route tables in modules/network-spoke degrade accordingly.
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "firewall" {
  count = var.deploy_firewall ? 1 : 0

  name                = "${var.name_prefix}-afw-pip"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard" # Basic SKU cannot be zone-redundant.
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_firewall_policy" "hub" {
  count = var.deploy_firewall ? 1 : 0

  name                = "${var.name_prefix}-afwp"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  sku                 = var.firewall_sku_tier
  tags                = var.tags

  # Threat intelligence in Alert-and-Deny mode blocks traffic to and from
  # known-malicious IPs and domains using Microsoft's feed. It costs nothing
  # extra and is the highest-value single setting on this resource.
  threat_intelligence_mode = "Alert"

  dns {
    proxy_enabled = true
    # DNS proxy matters more than it looks: it lets the firewall resolve the
    # FQDNs in application rules itself, so an FQDN rule stays correct when
    # the target's IP changes. Without it, FQDN rules are unreliable.
  }
}

resource "azurerm_firewall_policy_rule_collection_group" "egress" {
  count = var.deploy_firewall ? 1 : 0

  name               = "platform-egress"
  firewall_policy_id = azurerm_firewall_policy.hub[0].id
  priority           = 500

  # --- network rules: IP/port level -----------------------------------------

  network_rule_collection {
    name     = "platform-infrastructure"
    priority = 100
    action   = "Allow"

    rule {
      name              = "allow-ntp"
      description       = "Clock skew breaks TLS and Kerberos before it breaks anything else. Time sync is infrastructure."
      protocols         = ["UDP"]
      source_addresses  = ["*"]
      destination_fqdns = ["ntp.ubuntu.com"]
      destination_ports = ["123"]
    }

    rule {
      name                  = "allow-azure-control-plane"
      description           = "AKS nodes, Databricks and private endpoints all need the ARM and AAD control planes."
      protocols             = ["TCP"]
      source_addresses      = ["*"]
      destination_addresses = ["AzureCloud"]
      destination_ports     = ["443"]
    }
  }

  # --- application rules: FQDN level ----------------------------------------
  # Preferred over network rules wherever possible: an FQDN rule survives the
  # target changing IP, and it is legible to a reviewer. "Allow 443 to
  # 0.0.0.0/0" is not a security control; "allow 443 to *.azurecr.io" is.

  application_rule_collection {
    name     = "platform-egress-allowlist"
    priority = 200
    action   = "Allow"

    rule {
      name = "allow-approved-fqdns"
      protocols {
        type = "Https"
        port = 443
      }
      protocols {
        type = "Http"
        port = 80
      }
      source_addresses  = ["*"]
      destination_fqdns = var.allowed_egress_fqdns
    }
  }

  # --- terminal deny ---------------------------------------------------------
  # Azure Firewall already denies what it does not match. This collection is
  # here so the denial is *named* in the logs, which turns "why did this fail"
  # from an hour of guessing into one KQL query. See
  # docs/runbooks/03-egress-blocked.md.

  network_rule_collection {
    name     = "explicit-deny-all"
    priority = 65000
    action   = "Deny"

    rule {
      name                  = "deny-all-egress"
      protocols             = ["Any"]
      source_addresses      = ["*"]
      destination_addresses = ["*"]
      destination_ports     = ["*"]
    }
  }
}

resource "azurerm_firewall" "hub" {
  count = var.deploy_firewall ? 1 : 0

  name                = "${var.name_prefix}-afw"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  sku_name            = "AZFW_VNet"
  sku_tier            = var.firewall_sku_tier
  firewall_policy_id  = azurerm_firewall_policy.hub[0].id
  tags                = var.tags

  # Spread across all three zones in the region. This is free — zone
  # redundancy on Azure Firewall carries no SKU premium, only inter-zone data
  # transfer charges — and it is the difference between a 99.95% and a 99.99%
  # SLA on this resource.
  zones = ["1", "2", "3"]

  ip_configuration {
    name                 = "primary"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall[0].id
  }
}
