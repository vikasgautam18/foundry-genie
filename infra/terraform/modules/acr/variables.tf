variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "name_prefix" { type = string }
variable "name_suffix" {
  type    = string
  default = ""
}
variable "tags" { type = map(string) }
variable "public_network_access" { type = bool }
variable "public_pull" {
  type        = bool
  description = "If true, ACR is public-only (public access on, no private endpoint) so App Service can pull images."
  default     = false
}
variable "pe_subnet_id" { type = string }

variable "dns_zone_ids" {
  type        = map(string)
  description = "Map of private DNS zone name => id (from the networking module)."
}
