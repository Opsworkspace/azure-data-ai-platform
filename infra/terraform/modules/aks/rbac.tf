# ---------------------------------------------------------------------------
# Role assignments the cluster itself needs.
#
# Each of these is a permission granted to a MACHINE identity, and each is
# scoped as narrowly as the service allows. Note that there are two distinct
# identities in play, which is a frequent source of confusion:
#
#   The CLUSTER identity   manages Azure resources on the cluster's behalf:
#                          load balancers, public IPs, disks, route tables.
#   The KUBELET identity   is what the nodes themselves use, and is the one
#                          that pulls container images.
#
# Granting AcrPull to the cluster identity instead of the kubelet identity is
# a classic mistake: it produces ImagePullBackOff with an authentication error
# while the portal shows a correct-looking role assignment.
# ---------------------------------------------------------------------------

# Image pull, without an imagePullSecret anywhere in the cluster.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  count = var.container_registry_id != "" ? 1 : 0

  scope                = var.container_registry_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  principal_type       = "ServicePrincipal"

  description = "Lets nodes pull images. Must be the kubelet identity, not the cluster identity."
}

# The cluster identity needs to join nodes to the pre-existing subnets, which
# it does not own. Network Contributor on the subnet — not on the VNet, and
# certainly not on the resource group — is the least-privilege form.
resource "azurerm_role_assignment" "cluster_network_contributor" {
  for_each = toset([var.system_subnet_id, var.user_subnet_id, var.ai_subnet_id])

  scope                = each.value
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
  principal_type       = "ServicePrincipal"

  description = "Allows AKS to attach node NICs to this subnet."
}

# Managed Prometheus writes scraped metrics into the Azure Monitor workspace
# using the cluster's own identity.
resource "azurerm_role_assignment" "prometheus_publisher" {
  count = var.prometheus_workspace_id != "" ? 1 : 0

  scope                = var.prometheus_workspace_id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_kubernetes_cluster.this.oms_agent[0].oms_agent_identity[0].object_id
  principal_type       = "ServicePrincipal"
}
