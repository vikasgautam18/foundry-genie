#!/usr/bin/env bash
# ============================================================================
# package-teams-app.sh
#
# Builds a sideloadable Teams app package (teams-app.zip) from manifest.json,
# substituting the deployed bot app id and Teams host.
#
# Values are resolved in order: env var -> Terraform output.
#   BOT_APP_ID     (or: terraform output bot_app_id)
#   TEAMS_APP_URL  (or: terraform output teams_app_url)  -> host is derived
#
# Usage:
#   ./manifest/package-teams-app.sh
#   BOT_APP_ID=<guid> TEAMS_APP_URL=https://<host> ./manifest/package-teams-app.sh
#
# Output: manifest/build/teams-app.zip  (git-ignored)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../infra/terraform"

tf_out() {
  if [ -d "$TF_DIR" ] && command -v terraform >/dev/null 2>&1; then
    terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

BOT_APP_ID="${BOT_APP_ID:-$(tf_out bot_app_id)}"
TEAMS_APP_URL="${TEAMS_APP_URL:-$(tf_out teams_app_url)}"
TEAMS_HOST="${TEAMS_APP_URL#https://}"
TEAMS_HOST="${TEAMS_HOST#http://}"
TEAMS_HOST="${TEAMS_HOST%%/*}"

if [ -z "$BOT_APP_ID" ] || [ -z "$TEAMS_HOST" ]; then
  echo "[ERROR] Could not resolve BOT_APP_ID / TEAMS_APP_URL." >&2
  echo "        Set them as env vars or run after 'terraform apply'." >&2
  exit 1
fi

OUT_DIR="${SCRIPT_DIR}/build"
mkdir -p "$OUT_DIR"

sed -e "s|\${BOT_APP_ID}|${BOT_APP_ID}|g" \
    -e "s|\${TEAMS_HOST}|${TEAMS_HOST}|g" \
    "${SCRIPT_DIR}/manifest.json" > "${OUT_DIR}/manifest.json"

cp "${SCRIPT_DIR}/color.png" "${SCRIPT_DIR}/outline.png" "${OUT_DIR}/"

# Zip using python for portability (no 'zip' binary required).
python3 - "$OUT_DIR" <<'PY'
import json, os, sys, zipfile
d = sys.argv[1]
json.load(open(os.path.join(d, "manifest.json")))  # validate
z = os.path.join(d, "teams-app.zip")
with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as zf:
    for f in ("manifest.json", "color.png", "outline.png"):
        zf.write(os.path.join(d, f), f)  # flat, no folder prefix
print("Package created:", z)
PY

echo "  botId/id     : ${BOT_APP_ID}"
echo "  validDomains : ${TEAMS_HOST}"
echo "Upload manifest/build/teams-app.zip via Teams -> Apps -> Manage your apps -> Upload a custom app."
