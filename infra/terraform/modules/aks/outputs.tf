output "id" {
  description = "Cluster resource id."
  value       = azurerm_kubernetes_cluster.this.id
}

output "name" {
  description = "Cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL. This is the value federated identity credentials must trust — pass it to the identity module."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "cluster_identity_principal_id" {
  description = "Principal id of the cluster's user-assigned identity."
  value       = azurerm_user_assigned_identity.cluster.principal_id
}

output "kubelet_identity_object_id" {
  description = "Object id of the kubelet identity. This is the principal that pulls images and mounts Key Vault secrets — the one to grant AcrPull and Key Vault Secrets User to."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "key_vault_secrets_provider_identity_object_id" {
  description = "Object id of the Key Vault CSI driver's identity, which needs Key Vault Secrets User on any vault it mounts from."
  value       = azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].object_id
}

output "node_resource_group" {
  description = "The AKS-managed resource group holding nodes, disks and load balancers. Never modify its contents by hand: AKS reconciles it."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "private_fqdn" {
  description = "Private FQDN of the API server. Resolvable only from inside the VNet or a peered one."
  value       = azurerm_kubernetes_cluster.this.private_fqdn
}

output "kube_config_command" {
  description = "How an operator actually connects. Requires network line-of-sight to the private API server — from Bastion, a peered VNet, or `az aks command invoke`."
  value       = "az aks get-credentials --resource-group ${var.resource_group_name} --name ${var.name}"
}
