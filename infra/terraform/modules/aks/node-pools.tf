# ---------------------------------------------------------------------------
# User node pools.
#
# Why separate pools rather than one big one:
#
#   * Different hardware. An inference workload wants a GPU; an API pod wants
#     cheap general-purpose compute. Mixing them means paying GPU rates for
#     web servers.
#   * Different lifecycles. The AI pool can scale to zero overnight. The API
#     pool cannot.
#   * Different blast radius. A node-level failure or a bad node image affects
#     one pool.
#   * Different network policy. Each pool sits in its own subnet, so an NSG
#     can express rules a taint never could.
#
# Taints and labels work together: the taint keeps everything else OFF the
# pool, the label lets the intended workload FIND it via nodeSelector. A pool
# with a taint and no matching toleration in any deployment is a pool that
# scales to its minimum and runs nothing — an expensive and surprisingly
# common mistake.
# ---------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.user_node_pool.vm_size
  vnet_subnet_id        = var.user_subnet_id
  zones                 = var.user_node_pool.zones
  mode                  = "User"
  tags                  = var.tags

  auto_scaling_enabled = true
  min_count            = var.user_node_pool.min_count
  max_count            = var.user_node_pool.max_count

  # Ephemeral OS disks live on the VM's local NVMe rather than in remote
  # managed-disk storage. They are faster, free (included in the VM price),
  # and lost on deallocation — which is correct for a stateless node, and a
  # reason the VM SKU must have a large enough cache tier to hold the image.
  os_disk_type    = "Ephemeral"
  os_disk_size_gb = var.user_node_pool.os_disk_gb
  max_pods        = 110

  host_encryption_enabled = true
  node_public_ip_enabled  = false

  node_labels = {
    "workload-type" = "general"
  }

  upgrade_settings {
    max_surge = "33%"
  }

  lifecycle {
    ignore_changes = [node_count]
  }
}

# --- spot pool --------------------------------------------------------------
# Spot nodes are surplus Azure capacity at up to 90% off, evictable with 30
# seconds' notice. They are correct for anything that can be interrupted and
# retried — batch scoring, CI runners, queue workers — and catastrophic for
# anything that cannot.
#
# The taint is applied automatically by AKS for spot pools; it is repeated
# explicitly here so that a reader of the Terraform sees it without having to
# know that behaviour.

resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  count = var.user_node_pool.spot_pool ? 1 : 0

  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.user_node_pool.vm_size
  vnet_subnet_id        = var.user_subnet_id
  zones                 = var.user_node_pool.zones
  mode                  = "User"
  tags                  = var.tags

  priority        = "Spot"
  eviction_policy = "Delete"
  # -1 means "pay up to the standard on-demand price", i.e. never be evicted
  # for price reasons, only for capacity reasons. Setting a lower cap saves
  # money and increases eviction frequency.
  spot_max_price = -1

  auto_scaling_enabled = true
  min_count            = 0
  max_count            = var.user_node_pool.max_count

  os_disk_type            = "Ephemeral"
  os_disk_size_gb         = var.user_node_pool.os_disk_gb
  host_encryption_enabled = true
  node_public_ip_enabled  = false

  node_labels = {
    "workload-type"                         = "batch"
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }

  node_taints = [
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule",
  ]

  lifecycle {
    ignore_changes = [node_count]
  }
}

# --- AI / GPU pool ----------------------------------------------------------
# min_count = 0 by default. GPU SKUs are among the most expensive compute in
# Azure and are quota-limited per subscription per region; a pool that idles
# at one node costs more per month than the entire dev environment.

resource "azurerm_kubernetes_cluster_node_pool" "ai" {
  count = var.ai_node_pool.enabled ? 1 : 0

  name                  = "ai"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.ai_node_pool.vm_size
  vnet_subnet_id        = var.ai_subnet_id
  zones                 = var.ai_node_pool.zones
  mode                  = "User"
  tags                  = var.tags

  auto_scaling_enabled = true
  min_count            = var.ai_node_pool.min_count
  max_count            = var.ai_node_pool.max_count

  # Managed disk rather than ephemeral: GPU node images are large and the
  # cache on NC-series SKUs is not always big enough for an ephemeral disk.
  os_disk_type    = "Managed"
  os_disk_size_gb = var.ai_node_pool.os_disk_gb

  host_encryption_enabled = true
  node_public_ip_enabled  = false

  node_labels = {
    "workload-type" = "ai-inference"
    "accelerator"   = "nvidia"
  }

  node_taints = [
    "workload-type=ai-inference:NoSchedule",
  ]

  lifecycle {
    ignore_changes = [node_count]
  }
}
