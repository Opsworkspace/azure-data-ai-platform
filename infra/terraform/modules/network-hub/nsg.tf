# ---------------------------------------------------------------------------
# Network security groups for the hub.
#
# Note what is absent: there is no NSG on AzureFirewallSubnet. Azure forbids
# it — the firewall is itself the control point, and an NSG in front of it
# would break the service. Platform code has to know these exceptions, because
# a generic "attach an NSG to every subnet" policy would fail here.
# ---------------------------------------------------------------------------

# --- Bastion ---------------------------------------------------------------
# AzureBastionSubnet is the opposite case: Azure *requires* an NSG with this
# exact rule set. These rules are not a design choice, they are a contract.
# They are written out in full rather than hidden behind a service tag helper,
# because an operator debugging a broken Bastion needs to read them.

resource "azurerm_network_security_group" "bastion" {
  count = var.deploy_bastion ? 1 : 0

  name                = "${var.name_prefix}-bastion-nsg"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  tags                = var.tags

  # -- inbound --

  security_rule {
    name = "AllowHttpsInbound"
    # The only rule in this platform that accepts traffic from Internet — and it
    # terminates on a managed PaaS service, never on a VM we have to patch.
    description                = "Operators reach the Bastion portal over TLS."
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowGatewayManagerInbound"
    description                = "Azure control plane health probes and session setup."
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    description                = "Required for Bastion instances to stay in load balancer rotation."
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowBastionHostCommunication"
    description                = "Bastion instances communicate between themselves on 8080/5701."
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  # -- outbound --

  security_rule {
    name                       = "AllowSshRdpOutbound"
    description                = "Reach private hosts on 22/3389 with no public IP on the host."
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = "*"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowAzureCloudOutbound"
    description                = "Session diagnostics and dependency on Azure control plane."
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureCloud"
  }

  security_rule {
    name                       = "AllowBastionCommunication"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowGetSessionInformation"
    description                = "Bastion fetches session metadata over HTTP. Required by Azure."
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_subnet_network_security_group_association" "bastion" {
  count = var.deploy_bastion ? 1 : 0

  subnet_id                 = azurerm_subnet.bastion.id
  network_security_group_id = azurerm_network_security_group.bastion[0].id
}

# --- shared services -------------------------------------------------------
# Default-deny. Every NSG in this platform ends with an explicit deny rule at
# priority 4096 even though Azure's implicit default already denies, because
# an explicit rule shows up in flow logs and in NSG diagnostics as a named
# deny — an implicit one is much harder to attribute during an incident.

resource "azurerm_network_security_group" "shared" {
  name                = "${var.name_prefix}-shared-nsg"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  tags                = var.tags

  security_rule {
    name                       = "AllowVnetInbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "DenyAllInbound"
    description                = "Explicit terminal deny, so drops are attributable in flow logs."
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "shared" {
  subnet_id                 = azurerm_subnet.shared.id
  network_security_group_id = azurerm_network_security_group.shared.id
}
