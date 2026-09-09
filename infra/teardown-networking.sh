#!/usr/bin/env bash
# ============================================================================
# teardown-networking.sh
#
# Removes all resources created by setup-networking.sh, in reverse
# dependency order:
#   1. Disassociate NSG from subnets
#   2. Delete NSG
#   3. Delete private endpoints (Databricks + Foundry)
#   4. Delete VNet links from DNS zones
#   5. Delete private DNS zones
#
# Prerequisites:
#   • Azure CLI logged in (`az login`)
#   • Terraform state is still available (for auto-resolving names)
#
# Usage:
#   chmod +x infra/teardown-networking.sh
#   SUBSCRIPTION_ID=<your-sub-id> ./infra/teardown-networking.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"

tf_output() {
  if [ -d "$TF_DIR" ] && command -v terraform &>/dev/null; then
    terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# ── Configuration ────────────────────────────────────────────────────────

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID}"
RESOURCE_GROUP="${RESOURCE_GROUP:-$(tf_output resource_group_name)}"
RESOURCE_GROUP="${RESOURCE_GROUP:-teams-genie-demo}"

MAIN_VNET_NAME="${MAIN_VNET_NAME:-$(tf_output main_vnet_name)}"
MAIN_VNET_NAME="${MAIN_VNET_NAME:-foundry-genie-vnet}"

PE_SUBNET="${PE_SUBNET:-$(tf_output pe_subnet_name)}"
PE_SUBNET="${PE_SUBNET:-private-endpoints-subnet}"
WEBAPP_SUBNET="${WEBAPP_SUBNET:-$(tf_output webapp_subnet_name)}"
WEBAPP_SUBNET="${WEBAPP_SUBNET:-webapp-subnet}"

NSG_NAME="foundry-genie-nsg"

DNS_ZONES=(
  "privatelink.azuredatabricks.net"
  "privatelink.cognitiveservices.azure.com"
  "privatelink.services.ai.azure.com"
)

PRIVATE_ENDPOINTS=(
  "databricks-genie-pe"
  "foundry-pe"
)

echo "=== Foundry-Genie Networking Teardown ==="
echo "Subscription   : $SUBSCRIPTION_ID"
echo "Resource Group : $RESOURCE_GROUP"
echo "VNet           : $MAIN_VNET_NAME"
echo "NSG            : $NSG_NAME"
echo "PEs            : ${PRIVATE_ENDPOINTS[*]}"
echo "DNS Zones      : ${DNS_ZONES[*]}"
echo ""

az account set --subscription "$SUBSCRIPTION_ID"

# ── 1. Disassociate NSG from subnets ─────────────────────────────────────
echo "▶ Disassociating NSG from subnets..."

for SUBNET in "$PE_SUBNET" "$WEBAPP_SUBNET"; do
  az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$MAIN_VNET_NAME" \
    --name "$SUBNET" \
    --remove networkSecurityGroup \
    --output none 2>/dev/null && \
    echo "  Removed NSG from $SUBNET" || \
    echo "  (skip) $SUBNET — not found or no NSG attached"
done

# ── 2. Delete NSG ────────────────────────────────────────────────────────
echo ""
echo "▶ Deleting NSG..."

az network nsg delete \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NSG_NAME" \
  --output none 2>/dev/null && \
  echo "  Deleted $NSG_NAME" || \
  echo "  (skip) $NSG_NAME — not found"

# ── 3. Delete Private Endpoints ──────────────────────────────────────────
# Must be deleted before DNS zones (DNS zone groups are children of the PE).
echo ""
echo "▶ Deleting Private Endpoints..."

for PE in "${PRIVATE_ENDPOINTS[@]}"; do
  az network private-endpoint delete \
    --resource-group "$RESOURCE_GROUP" \
    --name "$PE" \
    --output none 2>/dev/null && \
    echo "  Deleted $PE" || \
    echo "  (skip) $PE — not found"
done

# ── 4. Delete VNet links from DNS zones ──────────────────────────────────
echo ""
echo "▶ Deleting VNet links from DNS zones..."

for ZONE in "${DNS_ZONES[@]}"; do
  LINK_NAME="${ZONE//./-}-link"
  az network private-dns link vnet delete \
    --resource-group "$RESOURCE_GROUP" \
    --zone-name "$ZONE" \
    --name "$LINK_NAME" \
    --yes \
    --output none 2>/dev/null && \
    echo "  Deleted link $LINK_NAME from $ZONE" || \
    echo "  (skip) $LINK_NAME — not found"
done

# ── 5. Delete Private DNS Zones ──────────────────────────────────────────
echo ""
echo "▶ Deleting Private DNS Zones..."

for ZONE in "${DNS_ZONES[@]}"; do
  az network private-dns zone delete \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ZONE" \
    --yes \
    --output none 2>/dev/null && \
    echo "  Deleted $ZONE" || \
    echo "  (skip) $ZONE — not found"
done

# ── Done ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "Networking teardown complete!"
echo ""
echo "  Terraform-managed resources (VNet, subnets,"
echo "  Databricks, Foundry, ACR, App Service) are"
echo "  NOT affected. Use 'terraform destroy' for those."
echo "============================================"
