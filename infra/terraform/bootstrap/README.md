# Terraform state bootstrap

Creates the **`genie_demo_rg`** resource group plus a Storage account + `tfstate`
container that back the **remote `azurerm` state** used by the root configuration
(`infra/terraform`).

> This step uses **local state** on purpose — it provisions the very storage the
> root module then uses as its backend. Because the state storage lives inside
> `genie_demo_rg`, it cannot be destroyed by the root state; delete the RG
> manually at teardown (after `terraform destroy` in the root).

## Usage

```bash
cd infra/terraform/bootstrap
terraform init
terraform apply            # review, then approve

# Wire the backend for the root module:
terraform output -raw backend_hcl > ../backend.hcl
```

Then initialise the root module against the remote backend:

```bash
cd ..
terraform init -backend-config=backend.hcl
```

## Notes

- `backend.hcl` is git-ignored (matches `**/*.hcl`? — no; it is ignored via the
  local `infra/terraform/.gitignore`). Never commit real backend values.
- The storage account name is `<state_sa_prefix><random>` truncated to 24 chars.
