# ---------------------------------------------------------------------------
# AKS — the compute substrate.
#
# A note on framing, because it matters more than any setting below: AKS is
# not the platform. It is one component of it. A team that installs AKS and
# declares victory has given its developers a Kubernetes API and a YAML
# problem. The platform is the whole path from commit to running, observable,
# secured workload, and this module is one link in it.
#
# The decisions worth understanding here:
#
# --- private cluster --------------------------------------------------------
# The API server has NO public endpoint. Not "a public endpoint restricted by
# IP allow-list" — no public endpoint. kubectl works from inside the VNet, from
# a peered VNet, or through Bastion. This costs real convenience: CI cannot
# reach the cluster without a self-hosted runner or `az aks command invoke`,
# and that inconvenience is the reason most teams do not do it. It is also the
# single largest reduction in attack surface available on a Kubernetes cluster.
#
# --- Azure CNI Overlay ------------------------------------------------------
# Three networking models, and the choice has permanent consequences:
#
#   kubenet          Pods get NATed addresses. Cheap on IPs, but no network
#                    policy support worth using, and being phased out.
#   Azure CNI        Every pod gets a real VNet IP. Directly routable, great
#                    for VNet-native traffic, but a 30-node cluster at 30 pods
#                    per node consumes 900 VNet addresses. Address exhaustion
#                    is the number one reason AKS clusters get rebuilt.
#   Azure CNI Overlay  Nodes get VNet IPs; pods get overlay IPs from a private
#                    CIDR that is NOT part of the VNet. Scales to hundreds of
#                    thousands of pods on a /22 of node addresses, keeps full
#                    network policy support, and the pod CIDR can be reused
#                    identically in every cluster.
#
# Overlay is chosen. The trade-off: a pod IP is not directly reachable from
# outside the cluster, so anything that needs to dial a pod directly (some
# service meshes, some legacy monitoring) needs adapting.
#
# --- outbound_type = userDefinedRouting ------------------------------------
# The cluster does NOT get its own outbound load balancer with a public IP.
# All egress follows the route table on the subnet, which sends it to the hub
# firewall. This is what makes the firewall's egress allow-list actually
# binding on Kubernetes workloads.
#
# It also means the subnet's route table MUST exist and be correct BEFORE the
# cluster is created. If it is not, node provisioning fails with a timeout,
# because the nodes cannot reach the AKS control plane to bootstrap.
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

# The cluster's own identity, created explicitly rather than letting AKS
# generate a system-assigned one. An explicit user-assigned identity survives
# cluster recreation, which means role assignments granted to it do not have
# to be re-granted — and it can be granted permissions BEFORE the cluster
# exists, breaking a genuine chicken-and-egg problem with private DNS zones.
resource "azurerm_user_assigned_identity" "cluster" {
  name                = "${var.name}-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier
  node_resource_group = var.node_resource_group_name

  # --- private cluster ------------------------------------------------------
  private_cluster_enabled = true
  # "System" lets AKS create and manage the privatelink.<region>.azmk8s.io
  # zone. The alternative — bringing your own zone — is only necessary when a
  # custom DNS server must resolve the API server, and it adds a permission
  # dependency that has to exist before the cluster does.
  private_dns_zone_id                 = "System"
  private_cluster_public_fqdn_enabled = false
  dns_prefix                          = replace(var.name, "-", "")

  # --- identity -------------------------------------------------------------
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cluster.id]
  }

  # --- workload identity ----------------------------------------------------
  # These two flags are what let a pod authenticate to Azure with no secret.
  # oidc_issuer_enabled publishes the cluster's OIDC discovery document;
  # workload_identity_enabled installs the mutating webhook that projects the
  # service account token into the pod. Both are required — enabling only one
  # produces a cluster where the federation silently never happens.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # --- Entra integration with Azure RBAC ------------------------------------
  # Kubernetes RBAC alone means a second, separate permission system with its
  # own bindings that nobody audits. Azure RBAC for Kubernetes makes cluster
  # permissions ordinary Azure role assignments, so they are visible to
  # Resource Graph, grantable through PIM, and revoked when someone leaves the
  # Entra group.
  #
  # local_account_disabled removes the cluster-admin certificate that bypasses
  # Entra entirely. Leaving it enabled means there is a credential that
  # answers to no identity provider, and `az aks get-credentials --admin`
  # hands it to anyone with Contributor on the cluster.
  local_account_disabled = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    admin_group_object_ids = var.admin_group_object_ids
  }

  # --- networking -----------------------------------------------------------
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"

    # Cilium as the data plane gives eBPF-based network policy and service
    # routing, replacing kube-proxy. It is the current default recommendation
    # for new clusters and performs better than iptables at this pod count.
    network_data_plane = "cilium"
    network_policy     = "cilium"

    pod_cidr       = var.pod_cidr
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip

    load_balancer_sku = "standard"

    # The setting that forces all egress through the hub firewall.
    outbound_type = "userDefinedRouting"
  }

  # --- node pool ------------------------------------------------------------
  # The system pool runs cluster-critical add-ons ONLY. only_critical_addons_enabled
  # applies the CriticalAddonsOnly taint, so application pods cannot schedule
  # here. Without it, a runaway application pod can starve CoreDNS, and DNS
  # failure inside a cluster looks like everything failing at once.
  default_node_pool {
    name           = "system"
    vm_size        = var.system_node_pool.vm_size
    vnet_subnet_id = var.system_subnet_id
    zones          = var.system_node_pool.zones

    auto_scaling_enabled = true
    min_count            = var.system_node_pool.min_count
    max_count            = var.system_node_pool.max_count

    only_critical_addons_enabled = true

    os_disk_type    = "Ephemeral"
    os_disk_size_gb = var.system_node_pool.os_disk_gb
    max_pods        = 110

    # Encrypts the node's temp disk and OS disk at the host, in addition to
    # the platform-managed encryption at rest of the underlying storage.
    host_encryption_enabled = true
    node_public_ip_enabled  = false

    upgrade_settings {
      # Surge 33% during upgrades: add a third more nodes, drain, remove.
      # Faster than one-at-a-time on a large pool, and it never reduces
      # capacity below the current level mid-upgrade.
      max_surge = "33%"
    }

    tags = var.tags
  }

  # --- add-ons --------------------------------------------------------------

  # Container Insights. msi_auth_for_monitoring_enabled uses the cluster's
  # managed identity rather than the workspace key, which is the difference
  # between a rotatable identity and a shared secret in a ConfigMap.
  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  # Managed Prometheus scraping. The allow-lists are empty by design: every
  # Kubernetes label promoted to a Prometheus label multiplies time-series
  # cardinality, and cardinality is what makes a metrics bill explode.
  dynamic "monitor_metrics" {
    for_each = var.prometheus_workspace_id != "" ? [1] : []
    content {
      annotations_allowed = null
      labels_allowed      = null
    }
  }

  # Gatekeeper (OPA) as a managed add-on. The constraints it enforces live in
  # platform/kubernetes/policy/ and in platform/policies/.
  azure_policy_enabled = true

  # Mounts Key Vault secrets as files in pods via CSI, so a secret is never a
  # Kubernetes Secret object sitting in etcd.
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # --- autoscaler tuning ----------------------------------------------------
  auto_scaler_profile {
    # Wait 10 minutes after a scale-up before considering any scale-down.
    # Aggressive scale-down causes thrashing: nodes removed, immediately
    # needed again, and every removal is a pod eviction.
    scale_down_delay_after_add = "10m"
    scale_down_unneeded        = "10m"

    # Bin-pack onto fewest nodes. "random" spreads load and costs more.
    expander = "least-waste"

    # Do not block scale-down on pods with local storage or non-replicated
    # kube-system pods. Left at defaults deliberately — overriding these is
    # how nodes get stuck undrainable.
    skip_nodes_with_local_storage = true
    skip_nodes_with_system_pods   = true
  }

  # --- upgrades -------------------------------------------------------------
  # Patch upgrades apply automatically inside the maintenance window; minor
  # version upgrades stay manual, because a minor upgrade can deprecate APIs
  # the workloads use. "Automatic patching, deliberate minor upgrades" is the
  # posture that keeps CVEs closed without surprise breakage.
  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = var.maintenance_day
    start_time  = "03:00"
    utc_offset  = "+00:00"
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = var.maintenance_day
    start_time  = "03:00"
    utc_offset  = "+00:00"
  }

  lifecycle {
    ignore_changes = [
      # The autoscaler owns node counts after creation. Terraform must not
      # fight it: a plan that resets node_count to the initial value would
      # scale production down mid-day.
      default_node_pool[0].node_count,
    ]

    precondition {
      condition     = var.sku_tier != "Free" || !can(regex("prod", var.name))
      error_message = "A production cluster must not use the Free SKU tier: it carries no control-plane SLA."
    }
  }
}
