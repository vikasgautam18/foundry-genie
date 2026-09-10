variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "name_prefix" { type = string }
variable "tags" { type = map(string) }
variable "sku" { type = string }
variable "public_network_access" { type = bool }

variable "workspace_public_network_access" {
  type        = bool
  description = "Front-end public access for the workspace itself (independent of PE creation)."
  default     = false
}
variable "pe_subnet_id" { type = string }
variable "dns_zone_ids" { type = map(string) }

variable "create_sql_warehouse" {
  type        = bool
  description = "Create a Pro SQL warehouse via the databricks provider (may need a two-step apply)."
  default     = false
}

# VNet injection (required so a private, public-access-disabled workspace is valid).
variable "virtual_network_id" { type = string }
variable "public_subnet_name" { type = string }
variable "private_subnet_name" { type = string }
variable "public_subnet_nsg_association_id" { type = string }
variable "private_subnet_nsg_association_id" { type = string }
