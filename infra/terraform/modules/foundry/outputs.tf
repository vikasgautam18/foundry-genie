output "account_id" {
  value = azapi_resource.account.id
}

output "account_name" {
  value = azapi_resource.account.name
}

output "account_principal_id" {
  description = "System-assigned MI principal ID of the Foundry account."
  value       = try(azapi_resource.account.output.identity.principalId, null)
}

output "project_id" {
  value = azapi_resource.project.id
}

output "project_name" {
  value = azapi_resource.project.name
}

output "project_principal_id" {
  description = "System-assigned MI principal ID of the Foundry project."
  value       = try(azapi_resource.project.output.identity.principalId, null)
}

output "project_endpoint" {
  description = "PROJECT_ENDPOINT consumed by the app (AgentsClient)."
  value       = "https://${local.subdomain}.services.ai.azure.com/api/projects/${local.project_name}"
}
