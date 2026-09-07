output "workload_identity_client_ids" {
  description = "Client id per workload. This is the value that goes into the Kubernetes ServiceAccount's azure.workload.identity/client-id annotation — it is an identifier, not a secret."
  value       = { for k, id in azurerm_user_assigned_identity.workload : k => id.client_id }
}

output "workload_identity_principal_ids" {
  description = "Principal (object) id per workload, for granting roles outside this module."
  value       = { for k, id in azurerm_user_assigned_identity.workload : k => id.principal_id }
}

output "workload_identity_ids" {
  description = "Full resource id per workload identity, for attaching to AKS or other services."
  value       = { for k, id in azurerm_user_assigned_identity.workload : k => id.id }
}

output "service_account_annotations" {
  description = "Ready-made annotation maps for each workload's Kubernetes ServiceAccount, so the manifest never hard-codes a client id."
  value = {
    for k, v in local.kubernetes_identities : k => {
      namespace       = v.kubernetes_namespace
      service_account = v.kubernetes_service_account
      annotations = {
        "azure.workload.identity/client-id" = azurerm_user_assigned_identity.workload[k].client_id
      }
    }
  }
}
