variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "name_prefix" { type = string }
variable "tags" { type = map(string) }
variable "vnet_address_space" { type = list(string) }
variable "pe_subnet_prefix" { type = string }
variable "webapp_subnet_prefix" { type = string }
variable "dbx_host_subnet_prefix" { type = string }
variable "dbx_container_subnet_prefix" { type = string }

variable "include_acr_dns" {
  type        = bool
  description = "Create the ACR private DNS zones/links. Set false when ACR is public-only (acr_public_pull) so ACR names resolve via public DNS."
  default     = true
}
