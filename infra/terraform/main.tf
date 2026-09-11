data "azurerm_client_config" "current" {}

# Resource group is created by ./bootstrap (holds ALL demo resources).
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

locals {
  tenant_id = coalesce(var.tenant_id, data.azurerm_client_config.current.tenant_id)

  suffix = var.name_suffix != "" ? var.name_suffix : random_string.suffix.result

  is_u2m       = var.databricks_auth_mode == "u2m"
  create_web   = true
  create_teams = true

  # Deterministic default hostnames. These break the bot<->appservice cycle AND
  # fix the code's hard-coded host mismatch: BOT_PUBLIC_URL / redirect URIs are
  # derived from the real app names created here. The suffix keeps the global
  # azurewebsites.net hostnames unique.
  web_app_name     = "${var.name_prefix}-web-${local.suffix}"
  teams_app_name   = "${var.name_prefix}-teams-${local.suffix}"
  web_public_url   = "https://${local.web_app_name}.azurewebsites.net"
  teams_public_url = "https://${local.teams_app_name}.azurewebsites.net"

  databricks_host = module.databricks.workspace_host

  # Which KV secrets to create (names are non-sensitive; keeps for_each valid).
  # Redis uses Entra auth (no connection string), so no redis-url secret.
  create_oauth_secret = local.is_u2m && nonsensitive(var.databricks_oauth_client_secret != "")
  secret_names = compact([
    "oauth-state-hmac-secret",
    local.create_oauth_secret ? "databricks-oauth-secret" : "",
    local.create_teams ? "bot-app-password" : "",
  ])
}

# Random suffix for globally-unique names (ACR/KV/Redis/Foundry/App Services).
resource "random_string" "suffix" {
  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false
}

# HMAC secret used by the Teams OAuth state-nonce fix (see src/teams changes).
resource "random_password" "oauth_state_hmac" {
  length  = 48
  special = false
}

module "networking" {
  source                      = "./modules/networking"
  resource_group_name         = data.azurerm_resource_group.rg.name
  location                    = var.location
  name_prefix                 = var.name_prefix
  tags                        = var.tags
  vnet_address_space          = var.vnet_address_space
  pe_subnet_prefix            = var.pe_subnet_prefix
  webapp_subnet_prefix        = var.webapp_subnet_prefix
  dbx_host_subnet_prefix      = var.dbx_host_subnet_prefix
  dbx_container_subnet_prefix = var.dbx_container_subnet_prefix
  include_acr_dns             = !var.acr_public_pull
}

module "acr" {
  source                = "./modules/acr"
  resource_group_name   = data.azurerm_resource_group.rg.name
  location              = var.location
  name_prefix           = var.name_prefix
  name_suffix           = local.suffix
  tags                  = var.tags
  public_network_access = var.public_network_access
  public_pull           = var.acr_public_pull
  pe_subnet_id          = module.networking.pe_subnet_id
  dns_zone_ids          = module.networking.dns_zone_ids
}

module "foundry" {
  source                = "./modules/foundry"
  resource_group_id     = data.azurerm_resource_group.rg.id
  resource_group_name   = data.azurerm_resource_group.rg.name
  location              = var.location
  account_location      = var.foundry_location
  name_prefix           = var.name_prefix
  name_suffix           = local.suffix
  tags                  = var.tags
  public_network_access = var.public_network_access
  pe_subnet_id          = module.networking.pe_subnet_id
  dns_zone_ids          = module.networking.dns_zone_ids
  model_deployment_name = var.foundry_model_deployment_name
  model_name            = var.foundry_model_name
  model_version         = var.foundry_model_version
  model_sku             = var.foundry_model_sku
  model_capacity        = var.foundry_model_capacity
}

module "databricks" {
  source                            = "./modules/databricks"
  resource_group_name               = data.azurerm_resource_group.rg.name
  location                          = var.location
  name_prefix                       = var.name_prefix
  tags                              = var.tags
  sku                               = var.databricks_sku
  public_network_access             = var.public_network_access
  workspace_public_network_access   = var.databricks_public_network_access
  pe_subnet_id                      = module.networking.pe_subnet_id
  dns_zone_ids                      = module.networking.dns_zone_ids
  create_sql_warehouse              = var.create_databricks_sql_warehouse
  virtual_network_id                = module.networking.vnet_id
  public_subnet_name                = module.networking.dbx_host_subnet_name
  private_subnet_name               = module.networking.dbx_container_subnet_name
  public_subnet_nsg_association_id  = module.networking.dbx_host_nsg_association_id
  private_subnet_nsg_association_id = module.networking.dbx_container_nsg_association_id
}

module "redis" {
  source                = "./modules/redis"
  count                 = local.is_u2m ? 1 : 0
  resource_group_name   = data.azurerm_resource_group.rg.name
  location              = var.location
  name_prefix           = var.name_prefix
  name_suffix           = local.suffix
  tags                  = var.tags
  sku_name              = var.redis_sku_name
  family                = var.redis_family
  capacity              = var.redis_capacity
  public_network_access = var.public_network_access
  pe_subnet_id          = module.networking.pe_subnet_id
  dns_zone_ids          = module.networking.dns_zone_ids
}

module "bot" {
  source                   = "./modules/bot"
  count                    = local.create_teams ? 1 : 0
  resource_group_name      = data.azurerm_resource_group.rg.name
  name_prefix              = var.name_prefix
  tags                     = var.tags
  tenant_id                = local.tenant_id
  bot_app_type             = var.bot_app_type
  bot_display_name         = var.bot_display_name
  teams_messaging_endpoint = "${local.teams_public_url}/api/messages"
}

module "keyvault" {
  source                = "./modules/keyvault"
  resource_group_name   = data.azurerm_resource_group.rg.name
  location              = var.location
  name_prefix           = var.name_prefix
  name_suffix           = local.suffix
  tags                  = var.tags
  tenant_id             = local.tenant_id
  public_network_access = var.public_network_access
  pe_subnet_id          = module.networking.pe_subnet_id
  dns_zone_ids          = module.networking.dns_zone_ids
  deployer_object_id    = data.azurerm_client_config.current.object_id

  secret_names = local.secret_names
  secrets = {
    "databricks-oauth-secret" = var.databricks_oauth_client_secret
    "oauth-state-hmac-secret" = random_password.oauth_state_hmac.result
    "bot-app-password"        = local.create_teams ? module.bot[0].bot_app_password : ""
  }
}

module "appservice" {
  source              = "./modules/appservice"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.location
  name_prefix         = var.name_prefix
  tags                = var.tags
  app_service_sku     = var.app_service_sku
  webapp_subnet_id    = module.networking.webapp_subnet_id
  create_web          = local.create_web
  create_teams        = local.create_teams
  web_app_name        = local.web_app_name
  teams_app_name      = local.teams_app_name

  acr_login_server      = module.acr.login_server
  web_container_image   = var.web_container_image
  teams_container_image = var.teams_container_image
  key_vault_name        = module.keyvault.key_vault_name

  project_endpoint           = module.foundry.project_endpoint
  model_deployment_name      = var.foundry_model_deployment_name
  databricks_host            = local.databricks_host
  genie_space_id             = var.genie_space_id
  databricks_auth_mode       = var.databricks_auth_mode
  databricks_oauth_client_id = var.databricks_oauth_client_id
  databricks_sp_client_id    = var.databricks_sp_client_id

  tenant_id    = local.tenant_id
  bot_app_id   = local.create_teams ? module.bot[0].bot_app_id : ""
  bot_app_type = var.bot_app_type

  web_public_url   = local.web_public_url
  teams_public_url = local.teams_public_url
  redis_host       = local.is_u2m ? module.redis[0].hostname : ""
  acr_public_pull  = var.acr_public_pull
}

module "rbac" {
  source = "./modules/rbac"
  app_principals = merge(
    local.create_web ? { web = module.appservice.web_principal_id } : {},
    local.create_teams ? { teams = module.appservice.teams_principal_id } : {},
  )
  acr_id                       = module.acr.acr_id
  key_vault_id                 = module.keyvault.key_vault_id
  foundry_project_id           = module.foundry.project_id
  foundry_account_id           = module.foundry.account_id
  foundry_project_principal_id = module.foundry.project_principal_id
  assign_project_mi            = true
  redis_id                     = local.is_u2m ? module.redis[0].redis_id : ""
  assign_redis                 = local.is_u2m
}
