# Entra app registration backing the bot (SingleTenant / MultiTenant).
# NOTE: UserAssignedMSI bots require a user-assigned identity instead of an app
# password; if bot_app_type = "UserAssignedMSI", wire that MI manually.
resource "azuread_application" "bot" {
  display_name     = "${var.name_prefix}-bot"
  sign_in_audience = var.bot_app_type == "MultiTenant" ? "AzureADMultipleOrgs" : "AzureADMyOrg"
}

resource "azuread_service_principal" "bot" {
  client_id = azuread_application.bot.client_id
}

resource "azuread_application_password" "bot" {
  application_id = azuread_application.bot.id
  display_name   = "bot-secret"
}

resource "azurerm_bot_service_azure_bot" "bot" {
  name                    = "${var.name_prefix}-bot"
  resource_group_name     = var.resource_group_name
  location                = "global"
  sku                     = "F0"
  microsoft_app_id        = azuread_application.bot.client_id
  microsoft_app_type      = var.bot_app_type
  microsoft_app_tenant_id = var.tenant_id
  endpoint                = var.teams_messaging_endpoint
  tags                    = var.tags
}

resource "azurerm_bot_channel_ms_teams" "teams" {
  bot_name            = azurerm_bot_service_azure_bot.bot.name
  location            = "global"
  resource_group_name = var.resource_group_name
}
