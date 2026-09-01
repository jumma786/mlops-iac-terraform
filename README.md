# mlops-iac-terraform

Infrastructure as Code for serving a machine learning model on Azure Container Apps.

Terraform provisions the registry, identity, logging and compute; a GitHub Actions
workflow plans on every pull request and applies on merge behind a manual approval.
It deploys the FastAPI service from
[`hospital-readmission-api`](https://github.com/jumma786/hospital-readmission-api),
but the image is a variable — any containerised model server works.

## Why this exists

A model that only runs on the machine that trained it is not deployed. The gap between
a working container and a running service is registry access, identity, ingress, scaling,
health probes and log routing — and doing that by hand in a portal means nobody can
reproduce it, review it, or roll it back.

This repository makes the environment a reviewable artefact: the same commit produces
the same infrastructure, a plan is posted onto the pull request before anything changes,
and `terraform destroy` removes it completely.

## What it creates

| Resource | Purpose |
|---|---|
| Resource group | Container for the stack; deletion is blocked while resources exist |
| Azure Container Registry (Basic) | Holds the model-serving image. **Admin user disabled** |
| User-assigned managed identity | Pulls from the registry — no registry password exists |
| `AcrPull` role assignment | Least-privilege grant: pull only, scoped to this one registry |
| Log Analytics workspace | Container stdout/stderr, queryable in KQL |
| Container Apps environment | Managed runtime backed by that workspace |
| Container App | The API: HTTPS ingress, liveness + readiness probes, autoscaling |

**Design decisions worth noting**

- **No secrets.** The app pulls images with a managed identity and CI authenticates
  through OIDC federation, so no registry password or service-principal secret is stored.
- **Readiness separate from liveness.** Readiness holds traffic back while the model
  loads; liveness restarts a replica that has stopped serving. Collapsing them into one
  probe either sends traffic to a cold model or restarts a healthy one.
- **Scale to zero by default** (`min_replicas = 0`) — no idle cost, at the price of
  cold-start latency. Set it to 1 where p99 matters.
- **HTTP-concurrency scaling** rather than CPU: inference latency degrades on queueing
  before it degrades on CPU.

## Prerequisites

- Terraform >= 1.6
- Azure CLI, logged in: `az login`
- An Azure subscription with Contributor rights

## Running it

```bash
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

The first apply creates the registry and the app. The app will report an unhealthy
revision until an image exists — push one, then the revision goes healthy:

```bash
ACR=$(terraform output -raw acr_name)
az acr login --name "$ACR"
docker tag readmission-api:latest "$(terraform output -raw acr_login_server)/readmission-api:latest"
docker push "$(terraform output -raw acr_login_server)/readmission-api:latest"
```

Then check it:

```bash
curl "$(terraform output -raw health_url)"
```

### Tearing it down

```bash
terraform destroy
```

Container Apps and a Basic registry cost roughly a few pounds a month at
`min_replicas = 0`; destroy when finished regardless.

### Remote state

State is local by default so a first run works with no setup. For anything shared,
create a storage account and uncomment the `backend "azurerm"` block in
`providers.tf`, then `terraform init -migrate-state`.

## CI

`.github/workflows/terraform.yml`

- **Pull request** → `fmt -check`, `init -backend=false`, `validate`, then `plan` with
  the plan posted as a PR comment
- **Merge to main** → `apply`, gated on the `production` GitHub environment so a human
  approves before infrastructure changes
- Authentication via **OIDC federated credentials** — set `AZURE_CLIENT_ID`,
  `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` as repository secrets. No client secret.

`validate` deliberately runs without cloud credentials so it also passes on forks.

## Status

Verified as far as is possible without an Azure subscription attached.

| Check | Terraform 1.16.0 | Result |
|---|---|---|
| `terraform fmt -check -recursive` | ✅ | Clean (one alignment fix applied) |
| `terraform init -backend=false` | ✅ | azurerm v3.117.1, random v3.9.0, lock file written |
| `terraform validate` | ✅ | `Success! The configuration is valid.` |
| `terraform plan` | ⏳ | Requires Azure credentials — run it yourself |
| `terraform apply` | ⏳ | Not run; creates billable resources |

`validate` confirms the syntax, provider schema and resource arguments are correct —
every attribute here exists on the azurerm provider and is used correctly. It does not
confirm the deployment succeeds; only `plan` and `apply` against a real subscription do
that.

To finish verifying:

```bash
az login
cd terraform
terraform plan
```

**Honest note:** this provisions a small, single-environment stack. It is not a
multi-region, multi-subscription landing zone, and it has no policy or budget guardrails.
It is the deployment layer for one model-serving service, which is what it claims to be.
