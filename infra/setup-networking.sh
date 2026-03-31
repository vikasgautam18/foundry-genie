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
#   • The Foundry workspace and Databricks workspace already exist
#
# Usage:
#   chmod +x infra/setup-networking.sh
#   ./infra/setup-networking.sh
# ============================================================================
set -euo pipefail

# ── Configuration — edit these to match your environment ─────────────────

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID}"
RESOURCE_GROUP="${RESOURCE_GROUP:?Set RESOURCE_GROUP}"
LOCATION="${LOCATION:-eastus}"

# Existing VNet that Foundry's inbound rules allow (or create a new one)
VNET_NAME="${VNET_NAME:-foundry-genie-vnet}"
VNET_CIDR="10.0.0.0/16"

# Subnets
FOUNDRY_SUBNET="foundry-subnet"
FOUNDRY_SUBNET_CIDR="10.0.1.0/24"
WEBAPP_SUBNET="webapp-subnet"
WEBAPP_SUBNET_CIDR="10.0.2.0/24"
PE_SUBNET="private-endpoints-subnet"
PE_SUBNET_CIDR="10.0.3.0/24"

# Databricks workspace resource ID (find in Azure Portal → Properties)
DATABRICKS_RESOURCE_ID="${DATABRICKS_RESOURCE_ID:?Set DATABRICKS_RESOURCE_ID}"

# Foundry workspace resource ID
FOUNDRY_RESOURCE_ID="${FOUNDRY_RESOURCE_ID:?Set FOUNDRY_RESOURCE_ID}"

# App Service name for the Chainlit web app
APP_SERVICE_NAME="${APP_SERVICE_NAME:-foundry-genie-webapp}"
APP_SERVICE_PLAN="${APP_SERVICE_PLAN:-foundry-genie-plan}"

echo "=== Foundry-Genie Networking Setup ==="
echo "Subscription : $SUBSCRIPTION_ID"
echo "Resource Group: $RESOURCE_GROUP"
echo "Location      : $LOCATION"
echo ""

az account set --subscription "$SUBSCRIPTION_ID"

# ── 1. Virtual Network & Subnets ─────────────────────────────────────────

echo "▶ Creating VNet and subnets..."
az network vnet create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VNET_NAME" \
  --address-prefix "$VNET_CIDR" \
  --location "$LOCATION" \
  --output none

for SUBNET_ARGS in \
  "$FOUNDRY_SUBNET $FOUNDRY_SUBNET_CIDR" \
  "$WEBAPP_SUBNET $WEBAPP_SUBNET_CIDR" \
  "$PE_SUBNET $PE_SUBNET_CIDR"; do
  read -r SNAME SCIDR <<< "$SUBNET_ARGS"
  az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SNAME" \
    --address-prefix "$SCIDR" \
    --output none
  echo "Subnet $SNAME ($SCIDR)"
done

# Disable private-endpoint network policies on the PE subnet
az network vnet subnet update \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$PE_SUBNET" \
  --disable-private-endpoint-network-policies true \
  --output none

# ── 2. Private DNS Zones ─────────────────────────────────────────────────

echo ""
echo "Creating Private DNS Zones..."

DNS_ZONES=(
  "privatelink.azuredatabricks.net"
  "privatelink.api.azureml.ms"
  "privatelink.notebooks.azure.net"
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
    --virtual-network "$VNET_NAME" \
    --registration-enabled false \
    --output none 2>/dev/null || true
  echo "DNS Zone $ZONE linked to $VNET_NAME"
done

# ── 3. Private Endpoint: Databricks ──────────────────────────────────────

echo ""
echo "Creating Private Endpoint for Databricks workspace..."

az network private-endpoint create \
  --resource-group "$RESOURCE_GROUP" \
  --name "databricks-genie-pe" \
  --vnet-name "$VNET_NAME" \
  --subnet "$PE_SUBNET" \
  --private-connection-resource-id "$DATABRICKS_RESOURCE_ID" \
  --group-id "databricks_ui_api" \
  --connection-name "databricks-genie-connection" \
  --location "$LOCATION" \
  --output none

# Register DNS record
az network private-endpoint dns-zone-group create \
  --resource-group "$RESOURCE_GROUP" \
  --endpoint-name "databricks-genie-pe" \
  --name "databricks-dns-group" \
  --private-dns-zone "privatelink.azuredatabricks.net" \
  --zone-name "databricks" \
  --output none

echo "Databricks private endpoint created"

# ── 4. Private Endpoint: Azure AI Foundry ────────────────────────────────

echo ""
echo "Creating Private Endpoint for Foundry workspace..."

az network private-endpoint create \
  --resource-group "$RESOURCE_GROUP" \
  --name "foundry-workspace-pe" \
  --vnet-name "$VNET_NAME" \
  --subnet "$PE_SUBNET" \
  --private-connection-resource-id "$FOUNDRY_RESOURCE_ID" \
  --group-id "amlworkspace" \
  --connection-name "foundry-workspace-connection" \
  --location "$LOCATION" \
  --output none

az network private-endpoint dns-zone-group create \
  --resource-group "$RESOURCE_GROUP" \
  --endpoint-name "foundry-workspace-pe" \
  --name "foundry-dns-group" \
  --private-dns-zone "privatelink.api.azureml.ms" \
  --zone-name "foundry" \
  --output none

echo "Foundry private endpoint created"

# ── 5. NSG Rules ─────────────────────────────────────────────────────────

echo ""
echo "Creating Network Security Group..."

NSG_NAME="foundry-genie-nsg"
az network nsg create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NSG_NAME" \
  --location "$LOCATION" \
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

# Allow HTTPS outbound to AzureML / Foundry
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
  --destination-address-prefixes "AzureMachineLearning" \
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

# Associate NSG with subnets
for S in "$PE_SUBNET" "$WEBAPP_SUBNET"; do
  az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$S" \
    --network-security-group "$NSG_NAME" \
    --output none
done

echo "NSG $NSG_NAME created and associated"

# ── 6. App Service + VNet Integration ────────────────────────────────────

echo ""
echo "Creating App Service Plan and Web App..."

az appservice plan create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APP_SERVICE_PLAN" \
  --sku B1 \
  --is-linux \
  --location "$LOCATION" \
  --output none

az webapp create \
  --resource-group "$RESOURCE_GROUP" \
  --plan "$APP_SERVICE_PLAN" \
  --name "$APP_SERVICE_NAME" \
  --deployment-container-image-name "python:3.11-slim" \
  --output none

# Integrate App Service with the VNet (regional VNet integration)
az webapp vnet-integration add \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APP_SERVICE_NAME" \
  --vnet "$VNET_NAME" \
  --subnet "$WEBAPP_SUBNET" \
  --output none

# Route all outbound traffic through VNet
az webapp config appsettings set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APP_SERVICE_NAME" \
  --settings \
    WEBSITE_VNET_ROUTE_ALL=1 \
    WEBSITE_DNS_SERVER=168.63.129.16 \
  --output none

echo "App Service $APP_SERVICE_NAME with VNet integration"

# ── Done ─────────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "Networking setup complete!"
echo ""
echo "Next steps:"
echo "  1. Verify Databricks PE connectivity:"
echo "     nslookup adb-7405605020937909.9.azuredatabricks.net"
echo "     (should resolve to a 10.0.x.x private IP)"
echo ""
echo "  2. Deploy the Chainlit app to App Service:"
echo "     az webapp config container set \\"
echo "       --resource-group $RESOURCE_GROUP \\"
echo "       --name $APP_SERVICE_NAME \\"
echo "       --docker-custom-image-name <your-acr>.azurecr.io/foundry-genie:latest"
echo ""
echo "  3. Set app settings (env vars) on the App Service:"
echo "     az webapp config appsettings set \\"
echo "       --resource-group $RESOURCE_GROUP \\"
echo "       --name $APP_SERVICE_NAME \\"
echo "       --settings @.env"
echo "============================================"
