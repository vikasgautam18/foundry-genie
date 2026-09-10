output "bot_app_id" {
  description = "MICROSOFT_APP_ID for the Teams app settings."
  value       = azuread_application.bot.client_id
}

output "bot_app_password" {
  description = "MICROSOFT_APP_PASSWORD (client secret). Stored in Key Vault."
  value       = azuread_application_password.bot.value
  sensitive   = true
}

output "bot_name" {
  value = azurerm_bot_service_azure_bot.bot.name
}
