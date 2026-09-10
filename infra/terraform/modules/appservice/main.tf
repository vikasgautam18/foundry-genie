locals {
  kv = var.key_vault_name

  common_settings = {
    PROJECT_ENDPOINT      = var.project_endpoint
    MODEL_DEPLOYMENT_NAME = var.model_deployment_name
    DATABRICKS_HOST       = var.databricks_host
    GENIE_SPACE_ID        = var.genie_space_id
    DATABRICKS_AUTH_MODE  = var.databricks_auth_mode
    # Use Azure DNS so private-endpoint FQDNs (Foundry/Databricks/Redis/KV)
    # resolve over the VNet integration.
    WEBSITE_DNS_SERVER = "168.63.129.16"
  }

  sp_settings = var.databricks_sp_client_id != "" ? {
    DATABRICKS_SP_CLIENT_ID = var.databricks_sp_client_id
  } : {}

  # Secrets are injected via Key Vault references (resolved by the app's MI).
  # Redis uses Entra (managed identity) auth — no connection string / access key.
  u2m_settings = var.databricks_auth_mode == "u2m" ? {
    DATABRICKS_OAUTH_CLIENT_ID     = var.databricks_oauth_client_id
    DATABRICKS_OAUTH_CLIENT_SECRET = "@Microsoft.KeyVault(VaultName=${local.kv};SecretName=databricks-oauth-secret)"
    OAUTH_STATE_HMAC_SECRET        = "@Microsoft.KeyVault(VaultName=${local.kv};SecretName=oauth-state-hmac-secret)"
    REDIS_USE_ENTRA                = "true"
    REDIS_HOST                     = var.redis_host
    REDIS_PORT                     = "6380"
  } : {}

  web_settings = merge(local.common_settings, local.sp_settings, local.u2m_settings, {
    WEBSITES_PORT = "8000"
    }, var.databricks_auth_mode == "u2m" ? {
    DATABRICKS_OAUTH_REDIRECT_URI = "${var.web_public_url}/oauth/callback"
  } : {})

  teams_settings = merge(local.common_settings, local.sp_settings, local.u2m_settings, {
    WEBSITES_PORT           = "3978"
    PORT                    = "3978"
    MICROSOFT_APP_ID        = var.bot_app_id
    MICROSOFT_APP_TYPE      = var.bot_app_type
    MICROSOFT_APP_TENANT_ID = var.tenant_id
    MICROSOFT_APP_PASSWORD  = "@Microsoft.KeyVault(VaultName=${local.kv};SecretName=bot-app-password)"
    BOT_PUBLIC_URL          = var.teams_public_url
    }, var.databricks_auth_mode == "u2m" ? {
    DATABRICKS_OAUTH_REDIRECT_URI = "${var.teams_public_url}/oauth/callback"
  } : {})
}

resource "azurerm_service_plan" "plan" {
  name                = "${var.name_prefix}-plan"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.app_service_sku
  tags                = var.tags
}

resource "azurerm_linux_web_app" "web" {
  count                     = var.create_web ? 1 : 0
  name                      = var.web_app_name
  resource_group_name       = var.resource_group_name
  location                  = var.location
  service_plan_id           = azurerm_service_plan.plan.id
  https_only                = true
  virtual_network_subnet_id = var.webapp_subnet_id
  tags                      = var.tags

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on                               = true
    vnet_route_all_enabled                  = true
    container_registry_use_managed_identity = true

    application_stack {
      docker_image_name   = var.web_container_image
      docker_registry_url = "https://${var.acr_login_server}"
    }
  }

  app_settings = local.web_settings
}

resource "azurerm_linux_web_app" "teams" {
  count                     = var.create_teams ? 1 : 0
  name                      = var.teams_app_name
  resource_group_name       = var.resource_group_name
  location                  = var.location
  service_plan_id           = azurerm_service_plan.plan.id
  https_only                = true
  virtual_network_subnet_id = var.webapp_subnet_id
  tags                      = var.tags

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on                               = true
    vnet_route_all_enabled                  = true
    container_registry_use_managed_identity = true

    application_stack {
      docker_image_name   = var.teams_container_image
      docker_registry_url = "https://${var.acr_login_server}"
    }
  }

  app_settings = local.teams_settings
}

# vnet_image_pull_enabled is not exposed by azurerm 3.x on azurerm_linux_web_app,
# but is REQUIRED to pull container images from a private-endpoint-only ACR.
# Patch it via azapi.
resource "azapi_update_resource" "web_vnet_image_pull" {
  count       = var.create_web ? 1 : 0
  type        = "Microsoft.Web/sites@2023-12-01"
  resource_id = azurerm_linux_web_app.web[0].id
  body = {
    properties = {
      vnetImagePullEnabled = !var.acr_public_pull
    }
  }
}

resource "azapi_update_resource" "teams_vnet_image_pull" {
  count       = var.create_teams ? 1 : 0
  type        = "Microsoft.Web/sites@2023-12-01"
  resource_id = azurerm_linux_web_app.teams[0].id
  body = {
    properties = {
      vnetImagePullEnabled = !var.acr_public_pull
    }
  }
}
