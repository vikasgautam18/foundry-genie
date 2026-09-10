# ── Outputs consumed by infra/deploy-webapp.sh and setup-networking.sh ─────
output "resource_group_name" {
  value = data.azurerm_resource_group.rg.name
}

output "acr_name" {
  value = module.acr.acr_name
}

output "acr_login_server" {
  value = module.acr.login_server
}

output "app_service_name" {
  description = "Web (Chainlit) App Service name."
  value       = module.appservice.web_app_name
}

output "app_service_url" {
  value = module.appservice.web_app_default_hostname != null ? "https://${module.appservice.web_app_default_hostname}" : null
}

output "main_vnet_name" {
  value = module.networking.vnet_name
}

output "pe_subnet_name" {
  value = module.networking.pe_subnet_name
}

output "webapp_subnet_name" {
  value = module.networking.webapp_subnet_name
}

output "databricks_workspace_id" {
  value = module.databricks.workspace_id
}

output "databricks_workspace_url" {
  value = module.databricks.workspace_url
}

output "foundry_id" {
  value = module.foundry.account_id
}

output "foundry_endpoint" {
  description = "PROJECT_ENDPOINT for the app."
  value       = module.foundry.project_endpoint
}

# ── Additional outputs (new resources) ─────────────────────────────────────
output "databricks_host" {
  description = "DATABRICKS_HOST (bare hostname)."
  value       = local.databricks_host
}

output "model_deployment_name" {
  value = var.foundry_model_deployment_name
}

output "key_vault_name" {
  value = module.keyvault.key_vault_name
}

output "key_vault_uri" {
  value = module.keyvault.key_vault_uri
}

output "redis_host" {
  value = local.is_u2m ? module.redis[0].hostname : null
}

output "teams_app_service_name" {
  value = module.appservice.teams_app_name
}

output "teams_app_url" {
  value = local.create_teams ? local.teams_public_url : null
}

output "bot_app_id" {
  description = "MICROSOFT_APP_ID of the Teams bot registration."
  value       = local.create_teams ? module.bot[0].bot_app_id : null
}

output "web_public_url" {
  value = local.create_web ? local.web_public_url : null
}
