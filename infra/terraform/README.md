# Foundry Genie — Terraform Infrastructure

Provisions the **entire** Foundry Genie stack into a **new resource group
`genie_demo_rg`** (no reuse of existing resources), fully private, for the
**`u2m`** auth mode with **both** the Chainlit web app and the Teams bot.

> ⚠️ `terraform apply` creates **billable** resources (Databricks Premium,
> Azure Cache for Redis, App Service Plan, AI Foundry). Review `terraform plan`
> and get approval before applying.

## What Terraform creates

| Module | Resources |
|--------|-----------|
| `bootstrap/` | `genie_demo_rg` + Storage account/container for **remote state** (local state) |
| `networking` | VNet, `private-endpoints-subnet`, `webapp-subnet` (delegated), NSG (+rules), private DNS zones (incl. `privatelink.openai.azure.com` + ACR data zone) |
| `acr` | Premium Azure Container Registry + private endpoint |
| `foundry` | AIServices account (`allowProjectManagement`), Foundry **project**, model deployment, PE (via `azapi`) |
| `databricks` | Premium workspace (private link), `databricks_ui_api` + `browser_authentication` PEs, optional Pro SQL warehouse |
| `redis` | Azure Cache for Redis (TLS 6380) + PE (U2M token store) |
| `keyvault` | RBAC vault + secrets (`databricks-oauth-secret`, `oauth-state-hmac-secret`, `bot-app-password`) + PE |
| `appservice` | Plan + web (`:8000`) and teams (`:3978`) Linux container apps, system MIs, VNet integration, KV-referenced settings |
| `bot` | Entra app registration + Azure Bot + Teams channel |
| `rbac` | `AcrPull`, `Key Vault Secrets User`, **Foundry User** (`53ca6127-…`) assignments |

## Prerequisites

- `terraform >= 1.5`, `az login` (Owner / Foundry Account Owner on the subscription).
- Providers used: `azurerm`, `azuread`, `azapi`, `databricks`, `random`.
- Register providers: `Microsoft.CognitiveServices`, `Microsoft.Databricks`,
  `Microsoft.Cache`, `Microsoft.KeyVault`, `Microsoft.Web`, `Microsoft.Network`,
  `Microsoft.ContainerRegistry`, `Microsoft.BotService`.

## Order of operations

```bash
# 1) Remote-state bootstrap (creates genie_demo_rg + tfstate storage)
cd infra/terraform/bootstrap
terraform init && terraform apply
terraform output -raw backend_hcl > ../backend.hcl

# 2) Root init against the remote backend
cd ..
cp terraform.tfvars.example terraform.tfvars   # edit values; DO NOT commit
terraform init -backend-config=backend.hcl

# 3) Review & apply (get approval first)
terraform fmt -check && terraform validate
terraform plan -out tfplan
terraform apply tfplan
```

**Two-step apply for the SQL warehouse** (only if `create_databricks_sql_warehouse=true`):
the `databricks` provider is configured from the workspace this config creates,
so apply the workspace first if the provider config is "unknown":

```bash
terraform apply -target=module.databricks.azurerm_databricks_workspace.this
terraform apply
```

## Manual steps (NOT Terraform-managed)

These must be done in the Databricks / Teams consoles, then fed back into
`terraform.tfvars` (or env) and re-applied where noted:

1. **Enable partner-powered AI features** — Databricks Account Console →
   Settings → Feature enablement.
2. **Unity Catalog** — attach a metastore; grant `SELECT` on the tables the
   Genie agent will use.
3. **Create the Genie space/agent** — add tables + the SQL warehouse; copy the
   32-hex `space_id` into `genie_space_id`.
4. **U2M OAuth app** — Account Console → Settings → App connections → create a
   custom app (redirect `https://<teams-host>/oauth/callback` **and**
   `https://<web-host>/oauth/callback`, scope All APIs, client secret). Put the
   `client_id` in `databricks_oauth_client_id` and the secret in
   `databricks_oauth_client_secret` (via `TF_VAR_databricks_oauth_client_secret`).
5. **(oauth mode only)** Configure account/workload-identity **federation
   policy** and register the managed identity as a Databricks service principal
   (`databricks_sp_client_id`).
6. **Teams manifest** — update `manifest/manifest.json` `validDomains` +
   developer URLs to the real `teams_app_url`, then package
   (`manifest.json` + `color.png` + `outline.png`) and upload.
7. **Build & push images** — `DEPLOY_TEAMS=1 ./infra/deploy-webapp.sh` (or
   `az acr build` for `foundry-genie` and `foundry-genie-teams`).

## Key variables

| Variable | Default | Notes |
|----------|---------|-------|
| `location` | `centralindia` | Region for the VNet + most resources |
| `foundry_location` | `southindia` | Region for the Foundry account/model (needs GlobalStandard; centralindia lacks it). PE stays in the VNet region. |
| `name_suffix` | _(random)_ | Suffix for globally-unique names (ACR/KV/Redis/Foundry/App Services) |
| `resource_group_name` | `genie_demo_rg` | Created by bootstrap |
| `name_prefix` | `geniedemo` | Drives resource names (ACR/KV/Storage too) |
| `public_network_access` | `false` | Full-private posture |
| `databricks_auth_mode` | `u2m` | Drives Redis + OAuth secret |
| `create_databricks_sql_warehouse` | `false` | See two-step apply |
| `foundry_model_deployment_name` | `gpt-5.4` | `MODEL_DEPLOYMENT_NAME` (model `gpt-5.4`, version `2026-03-05`) |
| `app_service_sku` | `B1` | ≥ B1 for VNet integration |
| `bot_app_type` | `SingleTenant` | Bot registration audience |

Secrets (`databricks_oauth_client_secret`, etc.) must be supplied via
`TF_VAR_*` env vars or a **git-ignored** `terraform.tfvars` — never committed.

## Security & gotchas

- **App Service caches `:latest`** — a plain `az webapp restart` may reuse the
  cached image and NOT pick up a rebuilt `:latest`. Force a fresh pull by pinning
  the container to the new digest, then restart:
  `az webapp config container set -g <rg> -n <app> --container-image-name <acr>.azurecr.io/<img>@sha256:<digest> --container-registry-url https://<acr>.azurecr.io`
  (or push immutable per-build tags instead of `:latest`).
- **Redis 6.0** lacks `GETDEL` (6.2+) — the token store uses an atomic Lua
  `GET`+`DEL` for single-use OAuth state/PKCE consumption, so it works on 6.0.
- **App Service ↔ private ACR image pull:** App Service regional VNet
  integration can fail to pull from a private-endpoint-only ACR
  (`ImagePullFailure: Cannot resolve registry address`) even with correct DNS.
  If you hit this, set **`acr_public_pull = true`** — ACR becomes public-only
  (no private endpoint) while image auth stays managed-identity `AcrPull` and
  all other data planes (Foundry/Databricks/Redis/KV) remain private.
- **Redis uses Entra (managed identity) auth** — no access keys / connection
  string. The app MIs get the Redis **"Data Contributor"** access-policy
  assignment (in the `rbac` module), and the apps run with
  `REDIS_USE_ENTRA=true` + `REDIS_HOST`. This is required when tenant policy
  disables Redis access-key auth. Local dev can still use a key-based `REDIS_URL`.
- **State & secrets never committed** — `.gitignore` excludes `*.tfvars`,
  `backend.hcl`, `*.tfstate*`, `.terraform/`.
- **Key Vault provisioning access** — writing secrets from an external
  Terraform runner needs data-plane reachability. `keyvault` keeps the vault
  reachable during provisioning (`allow_deployer_data_plane=true`) while still
  creating a private endpoint. For a hardened setup, run Terraform from an
  in-VNet agent and flip that off.
- **Foundry azapi API version** — the account/project use
  `2025-04-01-preview` with `schema_validation_enabled=false`; bump if your
  tenant exposes a newer stable version.
- **Role propagation** — a `403` immediately after apply (KV secrets / Foundry)
  is usually propagation lag; re-run `terraform apply`.

## Teardown

```bash
terraform destroy                      # root resources
# then delete the RG + state storage created by bootstrap:
az group delete -n genie_demo_rg
```
