variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "name_prefix" { type = string }
variable "name_suffix" {
  type    = string
  default = ""
}
variable "tags" { type = map(string) }
variable "sku_name" { type = string }
variable "family" { type = string }
variable "capacity" { type = number }
variable "public_network_access" { type = bool }
variable "pe_subnet_id" { type = string }
variable "dns_zone_ids" { type = map(string) }
