# ── Azure context ────────────────────────────────────────────────────────
variable "subscription_id" {
  type        = string
  description = "Azure subscription ID. If null, uses ARM_SUBSCRIPTION_ID / az login."
  default     = null
}

variable "tenant_id" {
  type        = string
  description = "Entra ID tenant ID (for azuread provider and bot app registration). If null, uses az login context."
  default     = null
}

variable "location" {
  type        = string
  description = "Azure region for all resources."
  default     = "centralindia"
}

variable "resource_group_name" {
  type        = string
  description = "Existing resource group (created by ./bootstrap) that holds ALL demo resources."
  default     = "genie_demo_rg"
}

variable "name_prefix" {
  type        = string
  description = "Short prefix for resource names. Lowercase alphanumeric (used for ACR/Storage/KV names too)."
  default     = "geniedemo"
  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.name_prefix))
    error_message = "name_prefix must be 3-12 lowercase alphanumeric characters."
  }
}

variable "name_suffix" {
  type        = string
  description = "Suffix appended to globally-unique names (ACR/KV/Redis/Foundry/App Services). Leave blank to auto-generate a random 5-char suffix."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default = {
    project = "foundry-genie"
    env     = "demo"
    managed = "terraform"
  }
}

# ── Networking ───────────────────────────────────────────────────────────
variable "vnet_address_space" {
  type        = list(string)
  description = "Address space for the VNet."
  default     = ["10.0.0.0/16"]
}

variable "pe_subnet_prefix" {
  type        = string
  description = "CIDR for the private-endpoints subnet."
  default     = "10.0.3.0/24"
}

variable "webapp_subnet_prefix" {
  type        = string
  description = "CIDR for the App Service VNet-integration subnet (delegated to Microsoft.Web/serverFarms)."
  default     = "10.0.4.0/24"
}

variable "dbx_host_subnet_prefix" {
  type        = string
  description = "CIDR for the Databricks host (public) subnet (VNet injection)."
  default     = "10.0.1.0/24"
}

variable "dbx_container_subnet_prefix" {
  type        = string
  description = "CIDR for the Databricks container (private) subnet (VNet injection)."
  default     = "10.0.2.0/24"
}

variable "public_network_access" {
  type        = bool
  description = "If false (full private), data-plane resources disable public network access and rely on private endpoints."
  default     = false
}

variable "acr_public_pull" {
  type        = bool
  description = "Make ACR public-only (enable public access + skip its private endpoint/DNS override) so App Service can pull images. Workaround for the App Service <-> private-ACR image-pull DNS limitation. Other data planes stay private. Image auth still uses managed-identity AcrPull."
  default     = false
}

variable "databricks_public_network_access" {
  type        = bool
  description = "Open ONLY the Databricks workspace front-end to public access (e.g. to reach the workspace UI for Genie/UC/OAuth setup). Private endpoints are kept. Set back to false when done."
  default     = false
}

# ── Azure AI Foundry ─────────────────────────────────────────────────────
variable "foundry_location" {
  type        = string
  description = "Region for the Foundry account/project/model. Must support your model's GlobalStandard SKU (centralindia does NOT). The private endpoint stays in the VNet region (var.location)."
  default     = "southindia"
}

variable "foundry_model_deployment_name" {
  type        = string
  description = "MODEL_DEPLOYMENT_NAME used by the app (the DEPLOYMENT name, may differ from the model)."
  default     = "gpt-5.4"
}

variable "foundry_model_name" {
  type    = string
  default = "gpt-5.4"
}

variable "foundry_model_version" {
  type    = string
  default = "2026-03-05"
}

variable "foundry_model_sku" {
  type    = string
  default = "GlobalStandard"
}

variable "foundry_model_capacity" {
  type        = number
  description = "Deployment capacity (thousands of tokens/min)."
  default     = 50
}

# ── Databricks ───────────────────────────────────────────────────────────
variable "databricks_sku" {
  type        = string
  description = "Databricks workspace SKU (premium required for Private Link / OAuth apps)."
  default     = "premium"
}

variable "create_databricks_sql_warehouse" {
  type        = bool
  description = "Create a Pro SQL warehouse via the databricks provider. May require a two-step apply (see README)."
  default     = false
}

variable "databricks_auth_mode" {
  type        = string
  description = "App auth mode: oauth | pat | u2m."
  default     = "u2m"
  validation {
    condition     = contains(["oauth", "pat", "u2m"], var.databricks_auth_mode)
    error_message = "databricks_auth_mode must be one of: oauth, pat, u2m."
  }
}

variable "genie_space_id" {
  type        = string
  description = "GENIE_SPACE_ID. Created MANUALLY (see README); leave blank until then."
  default     = ""
}

variable "databricks_sp_client_id" {
  type        = string
  description = "DATABRICKS_SP_CLIENT_ID for workload identity federation (oauth mode, managed identity). Optional."
  default     = ""
}

variable "databricks_oauth_client_id" {
  type        = string
  description = "u2m Databricks OAuth app client_id (created MANUALLY in the Account Console)."
  default     = ""
}

variable "databricks_oauth_client_secret" {
  type        = string
  description = "u2m Databricks OAuth app client secret (stored in Key Vault). Provide via tfvars/env, never commit."
  default     = ""
  sensitive   = true
}

# ── Redis ────────────────────────────────────────────────────────────────
variable "redis_sku_name" {
  type    = string
  default = "Standard"
}

variable "redis_family" {
  type    = string
  default = "C"
}

variable "redis_capacity" {
  type    = number
  default = 1
}

# ── App Service ──────────────────────────────────────────────────────────
variable "app_service_sku" {
  type        = string
  description = "App Service plan SKU (>= B1 supports VNet integration)."
  default     = "B1"
}

variable "web_container_image" {
  type        = string
  description = "Web (Chainlit) image name:tag in ACR."
  default     = "foundry-genie:latest"
}

variable "teams_container_image" {
  type        = string
  description = "Teams bot image name:tag in ACR."
  default     = "foundry-genie-teams:latest"
}

# ── Teams bot ────────────────────────────────────────────────────────────
variable "bot_app_type" {
  type        = string
  description = "MICROSOFT_APP_TYPE: SingleTenant | MultiTenant | UserAssignedMSI."
  default     = "SingleTenant"
  validation {
    condition     = contains(["SingleTenant", "MultiTenant", "UserAssignedMSI"], var.bot_app_type)
    error_message = "bot_app_type must be SingleTenant, MultiTenant, or UserAssignedMSI."
  }
}

variable "bot_display_name" {
  type    = string
  default = "Campaign Assistant"
}
