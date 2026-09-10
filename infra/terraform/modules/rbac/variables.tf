variable "app_principals" {
  type        = map(string)
  description = "Static-keyed map (e.g. {web=..., teams=...}) => app MI principal IDs. Keys must be known at plan time."
}

variable "acr_id" { type = string }
variable "key_vault_id" { type = string }
variable "foundry_project_id" { type = string }
variable "foundry_account_id" { type = string }

variable "foundry_project_principal_id" {
  type        = string
  description = "Foundry project's own MI principal ID (granted Foundry User on the account)."
  default     = null
}

variable "assign_project_mi" {
  type    = bool
  default = true
}

# ── Redis (Entra data-plane access for the app MIs) ────────────────────────
variable "redis_id" {
  type        = string
  description = "Azure Cache for Redis resource ID (for access-policy assignments)."
  default     = ""
}

variable "assign_redis" {
  type        = bool
  description = "Assign the Redis 'Data Contributor' access policy to each app MI (u2m mode)."
  default     = false
}
