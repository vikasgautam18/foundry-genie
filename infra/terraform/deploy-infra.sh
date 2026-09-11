#!/usr/bin/env bash
# ============================================================================
# deploy-infra.sh — Orchestrates Foundry Genie infrastructure provisioning in
# the correct order.
#
#   1) bootstrap  — create genie_demo_rg + remote-state storage (local state)
#   2) init       — init the root module against the azurerm remote backend
#   3) plan       — fmt + validate + plan  (-> tfplan)
#   4) apply      — apply tfplan  (BILLABLE; optional two-step for Databricks)
#   5) images     — build/push images + point App Services at them
#   6) output     — print outputs + remaining MANUAL steps
#
# Usage:
#   ./deploy-infra.sh <command>
#
#   Commands: bootstrap | init | plan | apply | images | output | all | destroy
#
# Env:
#   SUBSCRIPTION_ID=<sub>      Azure subscription (also honoured by providers)
#   AUTO_APPROVE=1             Skip interactive confirmations (CI)
#   REGISTER_PROVIDERS=1       az provider register the required RPs first
#   DATABRICKS_TWO_STEP=1      Apply the Databricks workspace before the full
#                             plan (needed if create_databricks_sql_warehouse=true)
#   DEPLOY_TEAMS=1             (images) also build/deploy the Teams bot image
#
# Examples:
#   SUBSCRIPTION_ID=xxxx ./deploy-infra.sh all
#   AUTO_APPROVE=1 SUBSCRIPTION_ID=xxxx ./deploy-infra.sh apply
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR"
BOOTSTRAP_DIR="$SCRIPT_DIR/bootstrap"
BACKEND_FILE="$SCRIPT_DIR/backend.hcl"
PLAN_FILE="$SCRIPT_DIR/tfplan"
APP_DEPLOY="$SCRIPT_DIR/../deploy-webapp.sh"

AUTO_APPROVE="${AUTO_APPROVE:-0}"
REGISTER_PROVIDERS="${REGISTER_PROVIDERS:-0}"
DATABRICKS_TWO_STEP="${DATABRICKS_TWO_STEP:-0}"

RESOURCE_PROVIDERS=(
  Microsoft.CognitiveServices
  Microsoft.Databricks
  Microsoft.Cache
  Microsoft.KeyVault
  Microsoft.Web
  Microsoft.Network
  Microsoft.ContainerRegistry
  Microsoft.BotService
  Microsoft.Storage
)

# ── helpers ────────────────────────────────────────────────────────────────
c_blue="\033[1;34m"; c_green="\033[1;32m"; c_yellow="\033[1;33m"; c_red="\033[1;31m"; c_off="\033[0m"
log()  { echo -e "${c_blue}▶ $*${c_off}"; }
ok()   { echo -e "${c_green}✔ $*${c_off}"; }
warn() { echo -e "${c_yellow}! $*${c_off}"; }
die()  { echo -e "${c_red}✘ $*${c_off}" >&2; exit 1; }

confirm() {
  # confirm "message"  → returns 0 if approved
  if [[ "$AUTO_APPROVE" == "1" ]]; then return 0; fi
  local ans
  read -r -p "$(echo -e "${c_yellow}$1 [type 'yes' to continue]:${c_off} ")" ans
  [[ "$ans" == "yes" ]]
}

approve_flag() { [[ "$AUTO_APPROVE" == "1" ]] && echo "-auto-approve" || echo ""; }

require_tools() {
  command -v terraform >/dev/null 2>&1 || die "terraform not found (see infra/install_terraform_hashicorp_apt.sh)."
  command -v az        >/dev/null 2>&1 || die "azure-cli (az) not found."
  az account show >/dev/null 2>&1 || die "Not logged in to Azure. Run: az login"
  if [[ -n "${SUBSCRIPTION_ID:-}" ]]; then
    az account set --subscription "$SUBSCRIPTION_ID"
  fi
  ok "Prerequisites present ($(terraform version | head -1))."
}

register_providers() {
  [[ "$REGISTER_PROVIDERS" == "1" ]] || return 0
  log "Registering resource providers (idempotent)..."
  for rp in "${RESOURCE_PROVIDERS[@]}"; do
    az provider register --namespace "$rp" --wait --only-show-errors >/dev/null 2>&1 || warn "could not register $rp"
  done
  ok "Resource providers registered."
}

# ── commands ───────────────────────────────────────────────────────────────
cmd_bootstrap() {
  require_tools
  register_providers
  log "Step 1/6 — Bootstrap remote state (creates genie_demo_rg + tfstate storage)"
  confirm "This creates a resource group and a Storage account. Proceed?" || die "Aborted."
  terraform -chdir="$BOOTSTRAP_DIR" init -input=false
  terraform -chdir="$BOOTSTRAP_DIR" apply $(approve_flag)
  terraform -chdir="$BOOTSTRAP_DIR" output -raw backend_hcl > "$BACKEND_FILE"
  ok "Wrote backend config -> $BACKEND_FILE"
}

cmd_init() {
  require_tools
  [[ -f "$BACKEND_FILE" ]] || die "backend.hcl missing. Run: $0 bootstrap"
  log "Step 2/6 — Initialise root module against remote backend"
  terraform -chdir="$TF_DIR" init -input=false -reconfigure -backend-config="$BACKEND_FILE"
  ok "Root module initialised."
}

cmd_plan() {
  require_tools
  log "Step 3/6 — Format, validate, plan"
  terraform -chdir="$TF_DIR" fmt -check -recursive || warn "run 'terraform fmt -recursive' to fix formatting"
  terraform -chdir="$TF_DIR" validate
  terraform -chdir="$TF_DIR" plan -input=false -out="$PLAN_FILE"
  ok "Plan written -> $PLAN_FILE"
}

cmd_apply() {
  require_tools
  log "Step 4/6 — Apply (creates BILLABLE resources)"

  # Databricks provider is configured from the workspace this config creates.
  # If the SQL warehouse is enabled, the workspace must exist before the full
  # plan can evaluate the databricks provider.
  if [[ "$DATABRICKS_TWO_STEP" == "1" ]]; then
    warn "Two-step Databricks: applying the workspace first..."
    confirm "Apply module.databricks.azurerm_databricks_workspace.this now?" || die "Aborted."
    terraform -chdir="$TF_DIR" apply $(approve_flag) \
      -target=module.databricks.azurerm_databricks_workspace.this
    ok "Databricks workspace applied."
  fi

  terraform -chdir="$TF_DIR" plan -input=false -out="$PLAN_FILE"
  confirm "Apply the plan above? This provisions real, billable Azure/Databricks resources." || die "Aborted."
  terraform -chdir="$TF_DIR" apply -input=false "$PLAN_FILE"
  ok "Infrastructure applied."
  cmd_output
}

cmd_images() {
  require_tools
  [[ -f "$APP_DEPLOY" ]] || die "app deploy script not found: $APP_DEPLOY"
  [[ -n "${SUBSCRIPTION_ID:-}" ]] || die "SUBSCRIPTION_ID is required for image build/deploy."
  log "Step 5/6 — Build & push images, point App Services at them"
  # deploy-webapp.sh reads Terraform outputs from this same TF dir.
  DEPLOY_TEAMS="${DEPLOY_TEAMS:-1}" SUBSCRIPTION_ID="$SUBSCRIPTION_ID" bash "$APP_DEPLOY"
  ok "Images deployed."
}

cmd_output() {
  require_tools
  log "Step 6/6 — Outputs & next steps"
  terraform -chdir="$TF_DIR" output || true
  cat <<'EOF'

────────────────────────────────────────────────────────────────────────────
REMAINING MANUAL STEPS (cannot be Terraform-managed) — see infra/terraform/README.md
  1. Databricks: enable "partner-powered AI features" (Account Console).
  2. Databricks: attach Unity Catalog + grant SELECT on the Genie tables.
  3. Databricks: create the Genie space; set GENIE_SPACE_ID (genie_space_id).
  4. Databricks: create the U2M OAuth app; set databricks_oauth_client_id and
     TF_VAR_databricks_oauth_client_secret, then re-run:  ./deploy-infra.sh apply
  5. Teams: update manifest/manifest.json validDomains to teams_app_url,
     package (manifest.json + color.png + outline.png) and upload.
  6. Build & deploy container images:   ./deploy-infra.sh images   (DEPLOY_TEAMS=1)
────────────────────────────────────────────────────────────────────────────
EOF
}

cmd_all() {
  cmd_bootstrap
  cmd_init
  cmd_apply        # runs plan + apply (+ optional two-step) and prints output
  warn "Infra applied. Fill the manual values (Genie space id, OAuth app) then:"
  warn "  ./deploy-infra.sh apply   # re-apply to wire secrets/settings"
  warn "  ./deploy-infra.sh images  # build & deploy container images"
}

cmd_destroy() {
  require_tools
  [[ -f "$BACKEND_FILE" ]] && terraform -chdir="$TF_DIR" init -input=false -reconfigure -backend-config="$BACKEND_FILE" >/dev/null 2>&1 || true
  warn "This DESTROYS all root-module resources in genie_demo_rg."
  confirm "Destroy the root module now?" || die "Aborted."
  terraform -chdir="$TF_DIR" destroy $(approve_flag)
  warn "Bootstrap resources (RG + tfstate storage) are NOT destroyed by root state."
  warn "Delete them manually when done:  az group delete -n genie_demo_rg"
}

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    bootstrap) cmd_bootstrap ;;
    init)      cmd_init ;;
    plan)      cmd_plan ;;
    apply)     cmd_init; cmd_apply ;;
    images)    cmd_images ;;
    output)    cmd_output ;;
    all)       cmd_all ;;
    destroy)   cmd_destroy ;;
    ""|-h|--help|help) usage ;;
    *) die "Unknown command: $cmd (run: $0 --help)" ;;
  esac
}

main "$@"
