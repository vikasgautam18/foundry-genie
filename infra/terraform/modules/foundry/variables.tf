variable "resource_group_id" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "account_location" {
  type        = string
  description = "Region for the Foundry account/project/model (may differ from the VNet/PE region)."
}
variable "name_prefix" { type = string }
variable "name_suffix" {
  type        = string
  description = "Suffix for the globally-unique account name + custom subdomain."
  default     = ""
}
variable "tags" { type = map(string) }
variable "public_network_access" { type = bool }
variable "pe_subnet_id" { type = string }
variable "dns_zone_ids" { type = map(string) }

variable "model_deployment_name" { type = string }
variable "model_name" { type = string }
variable "model_version" { type = string }
variable "model_sku" { type = string }
variable "model_capacity" { type = number }
