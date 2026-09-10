variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "name_prefix" { type = string }
variable "tags" { type = map(string) }
variable "app_service_sku" { type = string }
variable "webapp_subnet_id" { type = string }

variable "acr_login_server" { type = string }
variable "web_container_image" { type = string }
variable "teams_container_image" { type = string }
variable "key_vault_name" { type = string }

variable "create_web" {
  type    = bool
  default = true
}
variable "create_teams" {
  type    = bool
  default = true
}

variable "web_app_name" { type = string }
variable "teams_app_name" { type = string }

variable "redis_host" {
  type        = string
  description = "Azure Cache for Redis hostname (Entra auth; u2m mode)."
  default     = ""
}

variable "acr_public_pull" {
  type        = bool
  description = "When true, ACR is public-only; pull over the public path (vnetImagePull off). When false (private ACR), force the pull over the VNet."
  default     = false
}

# App configuration (env vars)
variable "project_endpoint" { type = string }
variable "model_deployment_name" { type = string }
variable "databricks_host" { type = string }
variable "genie_space_id" { type = string }
variable "databricks_auth_mode" { type = string }
variable "databricks_oauth_client_id" { type = string }
variable "databricks_sp_client_id" { type = string }

variable "tenant_id" { type = string }
variable "bot_app_id" { type = string }
variable "bot_app_type" { type = string }

variable "web_public_url" {
  type        = string
  description = "https://<web-host> (derived from the web app name)."
}
variable "teams_public_url" {
  type        = string
  description = "https://<teams-host> (derived from the teams app name); also BOT_PUBLIC_URL."
}
