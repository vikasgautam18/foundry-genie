#!/usr/bin/env bash
# ============================================================================
# deploy-webapp.sh
#
# Builds the Docker image, pushes it to ACR, and deploys to App Service.
#
# Prerequisites:
#   • Docker installed and running
#   • Azure CLI logged in
#   • ACR created (or set ACR_NAME to an existing one)
#   • setup-networking.sh already run
#
# Usage:
#   chmod +x infra/deploy-webapp.sh
#   ./infra/deploy-webapp.sh
# ============================================================================
set -euo pipefail

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID}"
RESOURCE_GROUP="${RESOURCE_GROUP:?Set RESOURCE_GROUP}"
LOCATION="${LOCATION:-eastus}"
ACR_NAME="${ACR_NAME:?Set ACR_NAME (e.g. foundrygenie)}"
APP_SERVICE_NAME="${APP_SERVICE_NAME:-foundry-genie-webapp}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

IMAGE_NAME="foundry-genie"
FULL_IMAGE="${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Deploying Foundry-Genie Web App ==="
echo "ACR          : $ACR_NAME"
echo "Image        : $FULL_IMAGE"
echo "App Service  : $APP_SERVICE_NAME"
echo ""

az account set --subscription "$SUBSCRIPTION_ID"

# ── 1. Ensure ACR exists ─────────────────────────────────────────────────

echo "Ensuring ACR exists..."
az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --sku Basic \
  --location "$LOCATION" \
  --admin-enabled true \
  --output none 2>/dev/null || true
echo "ACR $ACR_NAME ready"

# ── 2. Build & Push ──────────────────────────────────────────────────────

echo "Building and pushing Docker image..."
az acr build \
  --registry "$ACR_NAME" \
  --image "${IMAGE_NAME}:${IMAGE_TAG}" \
  --file "$PROJECT_DIR/Dockerfile" \
  "$PROJECT_DIR"
echo "Image pushed to $FULL_IMAGE"

# ── 3. Configure App Service ─────────────────────────────────────────────

echo "Configuring App Service container..."

# Give App Service permission to pull from ACR
az webapp config container set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APP_SERVICE_NAME" \
  --container-image-name "$FULL_IMAGE" \
  --container-registry-url "https://${ACR_NAME}.azurecr.io" \
  --output none

# Enable managed identity & grant ACR pull
az webapp identity assign \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APP_SERVICE_NAME" \
  --output none

WEBAPP_PRINCIPAL_ID=$(az webapp identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APP_SERVICE_NAME" \
  --query principalId -o tsv)

ACR_ID=$(az acr show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --query id -o tsv)

az role assignment create \
  --assignee "$WEBAPP_PRINCIPAL_ID" \
  --scope "$ACR_ID" \
  --role AcrPull \
  --output none

# ── 4. Set environment variables ─────────────────────────────────────────

echo "Setting application settings..."
echo "   (Make sure you have a .env file with your secrets)"

if [[ -f "$PROJECT_DIR/.env" ]]; then
  # Read .env and set as app settings (skip comments and empty lines)
  SETTINGS=""
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    # Strip surrounding quotes from value
    value="${value%\"}"
    value="${value#\"}"
    SETTINGS="$SETTINGS $key=$value"
  done < "$PROJECT_DIR/.env"

  if [[ -n "$SETTINGS" ]]; then
    az webapp config appsettings set \
      --resource-group "$RESOURCE_GROUP" \
      --name "$APP_SERVICE_NAME" \
      --settings $SETTINGS \
      --output none
  fi
  echo "App settings configured from .env"
else
  echo "No .env file found — set app settings manually"
fi

# ── 5. Restart ───────────────────────────────────────────────────────────

echo "Restarting web app..."
az webapp restart \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APP_SERVICE_NAME" \
  --output none

WEBAPP_URL="https://${APP_SERVICE_NAME}.azurewebsites.net"
echo ""
echo "============================================"
echo "Deployment complete!"
echo "   URL: $WEBAPP_URL"
echo ""
echo "   Test: curl -s $WEBAPP_URL | head -20"
echo "============================================"
