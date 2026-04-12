#!/usr/bin/env bash
# ============================================================================
# deploy-webapp.sh
#
# Builds the Docker image, pushes it to ACR, configures the App Service,
# and restarts it. ACR and App Service are created by Terraform.
#
# Prerequisites:
#   • Azure CLI logged in
#   • Terraform has been applied (infra/terraform/)
#   • setup-networking.sh already run
#
# Usage:
#   chmod +x infra/deploy-webapp.sh
#
#   # All values auto-read from Terraform state — just set your subscription:
#   SUBSCRIPTION_ID=<your-sub-id> ./infra/deploy-webapp.sh
#
#   # Override image tag:
#   SUBSCRIPTION_ID=<sub> IMAGE_TAG=v1.2.3 ./infra/deploy-webapp.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

ACR_NAME="${ACR_NAME:-$(tf_output acr_name)}"
if [ -z "$ACR_NAME" ]; then
  echo "[ERROR] ACR_NAME is not set and could not be read from Terraform output." >&2
  exit 1
fi

APP_SERVICE_NAME="${APP_SERVICE_NAME:-$(tf_output app_service_name)}"
if [ -z "$APP_SERVICE_NAME" ]; then
  echo "[ERROR] APP_SERVICE_NAME is not set and could not be read from Terraform output." >&2
  exit 1
fi

ACR_LOGIN_SERVER="${ACR_LOGIN_SERVER:-$(tf_output acr_login_server)}"
ACR_LOGIN_SERVER="${ACR_LOGIN_SERVER:-${ACR_NAME}.azurecr.io}"

IMAGE_NAME="foundry-genie"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"

echo "=== Deploying Foundry-Genie Web App ==="
echo "Resource Group: $RESOURCE_GROUP"
echo "ACR           : $ACR_NAME ($ACR_LOGIN_SERVER)"
echo "Image         : $FULL_IMAGE"
echo "App Service   : $APP_SERVICE_NAME"
echo ""

az account set --subscription "$SUBSCRIPTION_ID"

# ── 1. Build & Push ──────────────────────────────────────────────────────

echo "▶ Building and pushing Docker image..."
az acr build \
  --registry "$ACR_NAME" \
  --image "${IMAGE_NAME}:${IMAGE_TAG}" \
  --file "$PROJECT_DIR/Dockerfile" \
  "$PROJECT_DIR"
echo "  Image pushed to $FULL_IMAGE"

# ── 2. Configure App Service to use managed identity for ACR ─────────────

echo ""
echo "▶ Configuring App Service to pull from ACR via managed identity..."
az resource update \
  --ids "$(az webapp show -g "$RESOURCE_GROUP" -n "$APP_SERVICE_NAME" --query id -o tsv)" \
  --set properties.siteConfig.acrUseManagedIdentityCreds=true \
  --output none

az webapp config container set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APP_SERVICE_NAME" \
  --container-image-name "$FULL_IMAGE" \
  --container-registry-url "https://${ACR_LOGIN_SERVER}" \
  --output none

echo "  ACR managed identity pull configured"

# ── 3. Set environment variables ─────────────────────────────────────────

echo ""
echo "▶ Setting application settings..."

if [[ -f "$PROJECT_DIR/.env" ]]; then
  SETTINGS=""
  while IFS= read -r line; do
    line="${line%%#*}"             # strip inline comments
    line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"  # trim trailing whitespace
    [[ -z "$line" ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    value="${value%\"}"
    value="${value#\"}"
    [[ -z "$key" ]] && continue
    SETTINGS="$SETTINGS $key=$value"
  done < "$PROJECT_DIR/.env"

  if [[ -n "$SETTINGS" ]]; then
    az webapp config appsettings set \
      --resource-group "$RESOURCE_GROUP" \
      --name "$APP_SERVICE_NAME" \
      --settings $SETTINGS \
      --output none
  fi
  echo "  App settings configured from .env"
else
  echo "  No .env file found — set app settings manually"
fi

# ── 4. Restart ───────────────────────────────────────────────────────────

echo ""
echo "▶ Restarting web app..."
az webapp restart \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APP_SERVICE_NAME" \
  --output none

WEBAPP_URL="$(tf_output app_service_url)"
WEBAPP_URL="${WEBAPP_URL:-https://${APP_SERVICE_NAME}.azurewebsites.net}"

echo ""
echo "============================================"
echo "Deployment complete!"
echo "   URL: $WEBAPP_URL"
echo ""
echo "   Test: curl -s $WEBAPP_URL | head -20"
echo "============================================"
