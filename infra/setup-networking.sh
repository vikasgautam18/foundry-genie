#!/usr/bin/env bash
# ============================================================================
# setup-networking.sh
#
# Sets up the private-network plumbing so that:
#   1. Azure AI Foundry can reach the Databricks Genie MCP endpoint
#   2. The Chainlit web app (on App Service) can reach Azure AI Foundry
#   3. All traffic stays on the Azure backbone (no public internet)
#
# Prerequisites:
#   • Azure CLI logged in (`az login`)
#   • Contributor + Network Contributor on the target subscription
#   • Terraform has been applied (infra/terraform/) — VNet, subnets,
#     Databricks (VNet-injected), and AI Foundry resources must exist
#
# Usage:
#   chmod +x infra/setup-networking.sh
#
#   # All values auto-read from Terraform state — just set your subscription:
#   SUBSCRIPTION_ID=<your-sub-id> ./infra/setup-networking.sh
#
#   # Or override any value explicitly:
#   SUBSCRIPTION_ID=<sub> RESOURCE_GROUP=teams-genie-demo \
#   ./infra/setup-networking.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"

# Helper: read a Terraform output value, or return empty string
tf_output() {
  if [ -d "$TF_DIR" ] && command -v terraform &>/dev/null; then
    terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# ── Configuration ────────────────────────────────────────────────────────
# Values are resolved in order: env var → terraform output → default

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID}"
RESOURCE_GROUP="${RESOURCE_GROUP:-$(tf_output resource_group_name)}"
RESOURCE_GROUP="${RESOURCE_GROUP:-teams-genie-demo}"

# Main VNet (centralindia) — Databricks, App Service, private endpoints
MAIN_VNET_NAME="${MAIN_VNET_NAME:-$(tf_output main_vnet_name)}"
MAIN_VNET_NAME="${MAIN_VNET_NAME:-foundry-genie-vnet}"
MAIN_LOCATION="centralindia"

# Subnet names (created by Terraform)
PE_SUBNET="${PE_SUBNET:-$(tf_output pe_subnet_name)}"
PE_SUBNET="${PE_SUBNET:-private-endpoints-subnet}"
WEBAPP_SUBNET="${WEBAPP_SUBNET:-$(tf_output webapp_subnet_name)}"
WEBAPP_SUBNET="${WEBAPP_SUBNET:-webapp-subnet}"

PE_SUBNET_CIDR="10.0.3.0/24"
WEBAPP_SUBNET_CIDR="10.0.4.0/24"

# Resource IDs — auto-resolve from Terraform
DATABRICKS_RESOURCE_ID="${DATABRICKS_RESOURCE_ID:-$(tf_output databricks_workspace_id)}"
if [ -z "$DATABRICKS_RESOURCE_ID" ]; then
  echo "[ERROR] DATABRICKS_RESOURCE_ID is not set and could not be read from Terraform output." >&2
  echo "        Run 'terraform apply' in ${TF_DIR} first, or set the variable explicitly." >&2
  exit 1
fi

FOUNDRY_RESOURCE_ID="${FOUNDRY_RESOURCE_ID:-$(tf_output foundry_id)}"
if [ -z "$FOUNDRY_RESOURCE_ID" ]; then
  echo "[ERROR] FOUNDRY_RESOURCE_ID is not set and could not be read from Terraform output." >&2
  echo "        Run 'terraform apply' in ${TF_DIR} first, or set the variable explicitly." >&2
  exit 1
fi

# App Service (read from Terraform, used in summary output)
APP_SERVICE_NAME="${APP_SERVICE_NAME:-$(tf_output app_service_name)}"
APP_SERVICE_NAME="${APP_SERVICE_NAME:-foundry-genie-webapp}"

echo "=== Foundry-Genie Networking Setup ==="
echo "Subscription        : $SUBSCRIPTION_ID"
echo "Resource Group      : $RESOURCE_GROUP"
echo "VNet                : $MAIN_VNET_NAME ($MAIN_LOCATION)"
echo "Databricks Resource : $DATABRICKS_RESOURCE_ID"
echo "Foundry Resource    : $FOUNDRY_RESOURCE_ID"
echo ""

az account set --subscription "$SUBSCRIPTION_ID"

# ── 1. Private DNS Zones ─────────────────────────────────────────────────
# DNS zones are linked to the main VNet so private endpoints resolve correctly.

echo "▶ Creating Private DNS Zones..."

DNS_ZONES=(
  "privatelink.azuredatabricks.net"
  "privatelink.cognitiveservices.azure.com"
  "privatelink.services.ai.azure.com"
)

for ZONE in "${DNS_ZONES[@]}"; do
  az network private-dns zone create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ZONE" \
    --output none 2>/dev/null || true

  az network private-dns link vnet create \
    --resource-group "$RESOURCE_GROUP" \
    --zone-name "$ZONE" \
    --name "${ZONE//./-}-link" \
    --virtual-network "$MAIN_VNET_NAME" \
    --registration-enabled false \
    --output none 2>/dev/null || true

  echo "  DNS Zone $ZONE linked to $MAIN_VNET_NAME"
done

# ── 2. Private Endpoint: Databricks ──────────────────────────────────────

echo ""
echo "▶ Creating Private Endpoint for Databricks workspace..."

az network private-endpoint create \
  --resource-group "$RESOURCE_GROUP" \
  --name "databricks-genie-pe" \
  --vnet-name "$MAIN_VNET_NAME" \
  --subnet "$PE_SUBNET" \
  --private-connection-resource-id "$DATABRICKS_RESOURCE_ID" \
  --group-id "databricks_ui_api" \
  --connection-name "databricks-genie-connection" \
  --location "$MAIN_LOCATION" \
  --output none

az network private-endpoint dns-zone-group create \
  --resource-group "$RESOURCE_GROUP" \
  --endpoint-name "databricks-genie-pe" \
  --name "databricks-dns-group" \
  --private-dns-zone "privatelink.azuredatabricks.net" \
  --zone-name "databricks" \
  --output none

echo "  Databricks private endpoint created"

# ── 3. Private Endpoint: Azure AI Foundry (CognitiveServices) ────────────

echo ""
echo "▶ Creating Private Endpoint for AI Foundry resource..."

az network private-endpoint create \
  --resource-group "$RESOURCE_GROUP" \
  --name "foundry-pe" \
  --vnet-name "$MAIN_VNET_NAME" \
  --subnet "$PE_SUBNET" \
  --private-connection-resource-id "$FOUNDRY_RESOURCE_ID" \
  --group-id "account" \
  --connection-name "foundry-connection" \
  --location "$MAIN_LOCATION" \
  --output none

az network private-endpoint dns-zone-group create \
  --resource-group "$RESOURCE_GROUP" \
  --endpoint-name "foundry-pe" \
  --name "foundry-dns-group" \
  --private-dns-zone "privatelink.cognitiveservices.azure.com" \
  --zone-name "foundry" \
  --output none

echo "  Foundry private endpoint created"

# Resolve the PE's private IP and add an A record in the services.ai.azure.com zone
FOUNDRY_PE_IP=$(az network private-endpoint show \
  --resource-group "$RESOURCE_GROUP" \
  --name "foundry-pe" \
  --query "customDnsConfigs[0].ipAddresses[0]" -o tsv 2>/dev/null)
FOUNDRY_SHORT_NAME="${FOUNDRY_RESOURCE_ID##*/}"

if [ -n "$FOUNDRY_PE_IP" ] && [ -n "$FOUNDRY_SHORT_NAME" ]; then
  az network private-dns record-set a add-record \
    --resource-group "$RESOURCE_GROUP" \
    --zone-name "privatelink.services.ai.azure.com" \
    --record-set-name "$FOUNDRY_SHORT_NAME" \
    --ipv4-address "$FOUNDRY_PE_IP" \
    --output none 2>/dev/null || true
  echo "  Added A record: ${FOUNDRY_SHORT_NAME}.privatelink.services.ai.azure.com → ${FOUNDRY_PE_IP}"
fi

# ── 4. NSG Rules ─────────────────────────────────────────────────────────

echo ""
echo "▶ Creating Network Security Group..."

NSG_NAME="foundry-genie-nsg"
az network nsg create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NSG_NAME" \
  --location "$MAIN_LOCATION" \
  --output none

# Allow HTTPS outbound to Databricks from PE subnet
az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name "allow-databricks-https" \
  --priority 100 \
  --direction Outbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 443 \
  --source-address-prefixes "$PE_SUBNET_CIDR" \
  --destination-address-prefixes "AzureDatabricks" \
  --output none

# Allow HTTPS outbound to CognitiveServices / Foundry (public service tag)
az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name "allow-webapp-to-pe-subnet" \
  --priority 105 \
  --direction Outbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 443 \
  --source-address-prefixes "$WEBAPP_SUBNET_CIDR" \
  --destination-address-prefixes "$PE_SUBNET_CIDR" \
  --output none

# Allow HTTPS outbound to CognitiveServices management endpoints
az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name "allow-foundry-https" \
  --priority 110 \
  --direction Outbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 443 \
  --source-address-prefixes "$WEBAPP_SUBNET_CIDR" \
  --destination-address-prefixes "CognitiveServicesManagement" \
  --output none

# ── OAuth / Teams Bot NSG rules ──────────────────────────────────────
# Required ONLY for the OAuth (workload identity federation) scenario
# where a Teams bot App Service needs to validate Bot Framework JWT
# tokens. login.botframework.com resolves to Azure App Service infra,
# which is NOT covered by the AzureBotService service tag — use
# AzureCloud instead. AzureActiveDirectory covers Entra ID endpoints.

# Allow HTTPS outbound to AzureCloud (covers login.botframework.com)
az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name "allow-botservice-https" \
  --priority 120 \
  --direction Outbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 443 \
  --source-address-prefixes "$WEBAPP_SUBNET_CIDR" \
  --destination-address-prefixes "AzureCloud" \
  --output none

# Allow HTTPS outbound to AzureActiveDirectory (login.microsoftonline.com)
az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name "allow-azuread-https" \
  --priority 130 \
  --direction Outbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 443 \
  --source-address-prefixes "$WEBAPP_SUBNET_CIDR" \
  --destination-address-prefixes "AzureActiveDirectory" \
  --output none

# Deny all other outbound (tighten as needed)
az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name "deny-all-outbound" \
  --priority 4096 \
  --direction Outbound \
  --access Deny \
  --protocol "*" \
  --destination-port-ranges "*" \
  --source-address-prefixes "*" \
  --destination-address-prefixes "*" \
  --output none

# Associate NSG with PE and webapp subnets
for S in "$PE_SUBNET" "$WEBAPP_SUBNET"; do
  az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$MAIN_VNET_NAME" \
    --name "$S" \
    --network-security-group "$NSG_NAME" \
    --output none
done

echo "  NSG $NSG_NAME created and associated"

# ── Done ─────────────────────────────────────────────────────────────────
# App Service, VNet integration, and ACR are managed by Terraform.

DATABRICKS_URL="${DATABRICKS_URL:-$(tf_output databricks_workspace_url)}"
FOUNDRY_ENDPOINT="${FOUNDRY_ENDPOINT:-$(tf_output foundry_endpoint)}"
APP_SERVICE_NAME="${APP_SERVICE_NAME:-$(tf_output app_service_name)}"
APP_SERVICE_NAME="${APP_SERVICE_NAME:-foundry-genie-webapp}"

echo ""
echo "============================================"
echo "Networking setup complete!"
echo ""
if [ -n "$DATABRICKS_URL" ]; then
echo "  1. Verify Databricks PE connectivity:"
echo "     nslookup ${DATABRICKS_URL}"
echo "     (should resolve to a 10.0.x.x private IP)"
else
echo "  1. Verify Databricks PE connectivity:"
echo "     nslookup <your-databricks-workspace-url>"
echo "     (should resolve to a 10.0.x.x private IP)"
fi
echo ""
if [ -n "$FOUNDRY_ENDPOINT" ]; then
echo "  2. Verify Foundry PE connectivity:"
echo "     nslookup ${FOUNDRY_ENDPOINT#https://}"
echo "     (should resolve to a 10.0.x.x private IP)"
fi
echo ""
echo "  3. Deploy the Chainlit app:"
echo "     ./infra/deploy-webapp.sh"
echo "============================================"
