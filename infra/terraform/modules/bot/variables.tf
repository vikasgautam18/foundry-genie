variable "resource_group_name" { type = string }
variable "name_prefix" { type = string }
variable "tags" { type = map(string) }
variable "tenant_id" { type = string }
variable "bot_app_type" { type = string }
variable "bot_display_name" { type = string }

variable "teams_messaging_endpoint" {
  type        = string
  description = "https://<teams-host>/api/messages (derived from the Teams App Service name)."
}
