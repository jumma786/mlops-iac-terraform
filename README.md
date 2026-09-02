<div align="center">

# mlops-iac-terraform

**Production-shaped infrastructure for serving a machine learning model on Azure Container Apps.**

Registry, identity, ingress, autoscaling, health probes and log routing — provisioned by
Terraform, reviewed as a plan on every pull request, applied behind a human gate.

[![terraform](https://github.com/jumma786/mlops-iac-terraform/actions/workflows/terraform.yml/badge.svg)](https://github.com/jumma786/mlops-iac-terraform/actions/workflows/terraform.yml)
![Terraform](https://img.shields.io/badge/terraform-%E2%89%A5%201.9-7B42BC?logo=terraform&logoColor=white)
![Azure](https://img.shields.io/badge/Azure-Container%20Apps-0078D4?logo=microsoftazure&logoColor=white)
![Secrets](https://img.shields.io/badge/stored%20secrets-none-2ea44f)

</div>

---

## Contents

- [Why this exists](#why-this-exists)
- [Architecture](#architecture)
- [What it creates](#what-it-creates)
- [Design decisions](#design-decisions)
- [Repository layout](#repository-layout)
- [Quick start](#quick-start)
- [Operations](#operations)
- [Configuration reference](#configuration-reference)
- [CI/CD](#cicd)
- [Security posture](#security-posture)
- [Cost](#cost)
- [Troubleshooting](#troubleshooting)
- [Verification status](#verification-status)
- [Limitations](#limitations)

---

## Why this exists

A model that only runs on the machine that trained it is not deployed.

The gap between a working container and a running service is registry access, identity,
ingress, scaling, health probes and log routing. Doing that by hand in a portal means
nobody can reproduce it, review it, or roll it back — and the person who clicked through
it becomes a single point of failure.

This repository makes the environment a reviewable artefact. The same commit produces the
same infrastructure, a plan is posted onto the pull request before anything changes, the
apply runs *that* plan rather than a fresh one, and `terraform destroy` removes it
completely.

It deploys the FastAPI service from
[`hospital-readmission-api`](https://github.com/jumma786/hospital-readmission-api), but the
image is a variable — any containerised model server works.

---

## Architecture

```mermaid
flowchart LR
    client(["Client"])

    subgraph ci["GitHub Actions"]
        direction TB
        v["fmt · validate<br/>tflint · trivy"]
        p["plan<br/>→ artifact"]
        a["apply<br/>production gate"]
        v --> p --> a
    end

    subgraph rg["Azure resource group"]
        direction TB
        ca["Container App<br/>HTTPS ingress · probes<br/>concurrency autoscale"]
        cae["Container Apps environment"]
        acr[("Container Registry<br/>admin user disabled")]
        mi["Managed identity"]
        law[("Log Analytics<br/>capped ingestion")]

        mi -->|AcrPull| acr
        ca -->|pull via identity| acr
        ca --> cae
        cae -->|stdout / stderr| law
    end

    a -.->|OIDC · no stored secrets| rg
    client -->|HTTPS| ca
```

The deploy loop has two moving parts, deliberately separated:

| Path | Trigger | Effect |
|---|---|---|
| **Infrastructure** | A pull request touching `terraform/` | Plan reviewed, then applied on merge |
| **Model** | A new image pushed to the registry | `terraform apply -var image_tag=<sha>` creates a new revision |

---

## What it creates

| Resource | Purpose |
|---|---|
| Resource group | Container for the stack; deletion is blocked while resources exist |
| Azure Container Registry (Basic) | Holds the model-serving image. **Admin user disabled** |
| User-assigned managed identity | Pulls from the registry — no registry password exists |
| `AcrPull` role assignment | Least-privilege grant: pull only, scoped to this one registry |
| Log Analytics workspace | Container stdout/stderr, queryable in KQL, with a daily ingestion cap |
| Container Apps environment | Managed runtime backed by that workspace |
| Container App | The API: HTTPS ingress, liveness + readiness probes, autoscaling |

---

## Design decisions

**No secrets, anywhere.** The app pulls images with a managed identity, CI authenticates
through OIDC federation, and the state container is reached with Azure AD rather than a
storage key. There is no registry password, service-principal secret or storage key to
leak, rotate or accidentally commit.

**Readiness is separate from liveness.** Readiness holds traffic back while the model
loads into memory; liveness restarts a replica that has stopped serving. Collapsing them
into one probe gives you a choice between sending traffic to a cold model and restarting
a healthy one — neither is acceptable.

**Immutable image tags, enforced at plan time.** `image_tag = "latest"` is rejected by a
variable validation. A mutable tag produces no diff, so re-pushing it changes nothing in
the plan and the running revision keeps serving the old model — silently. Pinning a build
SHA makes the tag change *the* signal that creates a new revision.

**Bootstrap mode removes the chicken-and-egg.** On a first apply the registry exists but is
empty, so pointing the app at an image that cannot be pulled produces a dead revision. With
`image_tag` unset the app runs a public placeholder instead, ingress follows its port, and
the probes are skipped — the first apply goes green. Push an image, set the tag, apply
again.

**Scale to zero by default.** `min_replicas = 0` removes idle cost at the price of
cold-start latency. Set it to `1` where p99 matters.

**Concurrency-based autoscaling, not CPU.** Inference latency degrades on request queueing
well before it degrades on CPU utilisation, so the scale trigger follows the signal that
actually predicts a slow response.

**The applied plan is the reviewed plan.** CI uploads the plan file and the apply job runs
it, rather than re-planning after approval. If state moved while approval was pending,
Terraform rejects the stale plan instead of applying something nobody looked at.

**Bounded blast radius on cost.** Log Analytics ingestion is the one line item here that
can bill without limit, so it carries an explicit daily cap.

---

## Repository layout

```
.
├── .github/workflows/terraform.yml   CI: validate → plan → gated apply
├── terraform/
│   ├── providers.tf                  Providers + partial remote-state backend
│   ├── variables.tf                  Inputs, with plan-time validation
│   ├── main.tf                       The stack
│   ├── outputs.tf                    Endpoints and resource names
│   ├── .tflint.hcl                   Lint rules (core + azurerm ruleset)
│   ├── backend.hcl.example           Copy to backend.hcl (gitignored)
│   └── terraform.tfvars.example      Copy to terraform.tfvars (gitignored)
└── README.md
```

---

## Quick start

### Prerequisites

| Requirement | Notes |
|---|---|
| Terraform >= 1.9 | The floor for cross-variable `validation` blocks, used to reject unsupported cpu/memory pairs at plan time |
| Azure CLI | `az login` |
| Azure subscription | Contributor on the target subscription |
| State storage account | Created once, below |

### 1 — Create the state backend

State is remote, not optional: a CI runner's local state is discarded when the job ends,
so every run would plan from empty and try to recreate a stack that already exists. The
backend is a *partial* configuration — `providers.tf` declares it, the storage account is
supplied at `init` time.

```bash
LOC=uksouth
RG=rg-tfstate
SA=sttfstate$RANDOM$RANDOM   # globally unique, 3-24 lowercase alphanumerics

az group create --name "$RG" --location "$LOC"

az storage account create \
  --name "$SA" --resource-group "$RG" --location "$LOC" \
  --sku Standard_LRS --kind StorageV2 \
  --allow-blob-public-access false --min-tls-version TLS1_2

# Versioning gives you a way back from a corrupted or truncated state file.
az storage account blob-service-properties update \
  --account-name "$SA" --resource-group "$RG" --enable-versioning true

az storage container create --name tfstate --account-name "$SA" --auth-mode login

# Data-plane access is separate from management-plane access: subscription Owner does
# not by itself let you read a blob. Grant the data role explicitly.
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --scope "$(az storage account show --name "$SA" --resource-group "$RG" --query id -o tsv)"
```

### 2 — Initialise

```bash
cd terraform
cp backend.hcl.example backend.hcl   # fill in the values; backend.hcl is gitignored
terraform init -backend-config=backend.hcl
```

### 3 — First apply (bootstrap)

```bash
terraform plan -out=tfplan
terraform apply tfplan

terraform output bootstrap_mode   # true — running the placeholder
terraform output api_url
```

### 4 — Ship the model

```bash
ACR=$(terraform output -raw acr_name)
REGISTRY=$(terraform output -raw acr_login_server)
TAG=$(git -C ../../hospital-readmission-api rev-parse --short HEAD)

az acr login --name "$ACR"
docker tag readmission-api:latest "$REGISTRY/readmission-api:$TAG"
docker push "$REGISTRY/readmission-api:$TAG"

terraform apply -var "image_tag=$TAG"
```

That second apply flips ingress to `container_port`, enables the health probes and creates
a new revision:

```bash
curl "$(terraform output -raw health_url)"
```

Put `image_tag` in `terraform.tfvars` (copy `terraform.tfvars.example`) if you would rather
not pass it on the command line.

---

## Operations

### Deploy a new model version

Build, push under a new immutable tag, and apply:

```bash
terraform apply -var "image_tag=$NEW_SHA"
```

The image string is part of the container spec, so the tag change *is* the diff that
creates a new revision. Traffic moves to it at 100% (`revision_mode = "Single"`).

### Roll back

Same command, previous tag:

```bash
terraform apply -var "image_tag=$PREVIOUS_SHA"
```

Rollback and roll-forward are the same operation, which is the point — there is no
separate, less-rehearsed recovery path to get wrong under pressure.

### Read logs

```bash
az containerapp logs show \
  --name "$(terraform output -raw container_app_name)" \
  --resource-group "$(terraform output -raw resource_group_name)" \
  --follow
```

Or query the workspace directly:

```kusto
ContainerAppConsoleLogs_CL
| where ContainerAppName_s startswith "ca-mlopsapi"
| project TimeGenerated, RevisionName_s, Log_s
| order by TimeGenerated desc
| take 200
```

Platform events — image pull failures, probe failures, scaling decisions — land in a
separate table:

```kusto
ContainerAppSystemLogs_CL
| where ContainerAppName_s startswith "ca-mlopsapi"
| project TimeGenerated, Reason_s, Log_s
| order by TimeGenerated desc
```

### Tune capacity

```bash
terraform apply -var min_replicas=1 -var max_replicas=10   # kill cold starts
```

### Tear down

```bash
terraform destroy
```

---

## Configuration reference

### Inputs

| Variable | Type | Default | Notes |
|---|---|---|---|
| `project` | `string` | `mlopsapi` | 3–12 lowercase alphanumerics; prefixes every resource name |
| `environment` | `string` | `dev` | One of `dev`, `test`, `prod` |
| `location` | `string` | `uksouth` | Azure region |
| `image_name` | `string` | `readmission-api` | Repository inside the registry |
| `image_tag` | `string` | `null` | `null` enables bootstrap mode. `latest` is rejected |
| `bootstrap_image` | `string` | `mcr.microsoft.com/k8se/quickstart:latest` | Placeholder used while no tag is set |
| `bootstrap_port` | `number` | `80` | Port the placeholder listens on |
| `container_port` | `number` | `8000` | Port your model server listens on |
| `cpu` | `number` | `0.5` | Must pair with `memory` |
| `memory` | `string` | `1Gi` | Exactly 2 GiB per vCPU; validated |
| `min_replicas` | `number` | `0` | `0` = scale to zero |
| `max_replicas` | `number` | `3` | 1–300 |
| `log_retention_days` | `number` | `30` | 30–730 for the `PerGB2018` SKU |
| `log_daily_quota_gb` | `number` | `1` | `-1` removes the cap |
| `tags` | `map(string)` | see `variables.tf` | Merged with `environment` and `project` |

Invalid values fail at **plan** time, not thirty seconds into an apply:

```
Error: Invalid value for variable
  Unsupported cpu/memory pair. Container Apps allows 0.25/0.5Gi, 0.5/1Gi, ...
```

### Outputs

| Output | Description |
|---|---|
| `api_url` | Public HTTPS endpoint |
| `health_url` | Endpoint backing the probes |
| `acr_name` / `acr_login_server` | For `az acr login` and image tagging |
| `deployed_image` | Image the current revision runs |
| `bootstrap_mode` | `true` while serving the placeholder |
| `container_app_name` | App name, for `az containerapp` commands |
| `resource_group_name` | Resource group holding the stack |
| `log_analytics_workspace` | Workspace to query with KQL |

---

## CI/CD

`.github/workflows/terraform.yml`

| Stage | Runs on | Does |
|---|---|---|
| `validate` | Every PR and push | `fmt -check`, `init -backend=false`, `validate`, TFLint, Trivy config scan |
| `plan` | Every PR and push (not forks) | `terraform plan`, posts it as a PR comment, uploads the plan file |
| `apply` | Push to `main` only | Downloads the approved plan and applies **that file** |

Properties worth noting:

- **The apply is not a re-plan.** The plan file is passed forward as a build artefact. A
  stale plan is rejected rather than silently re-derived after approval.
- **A human gate.** `apply` targets the `production` GitHub environment, so a reviewer
  approves before infrastructure changes land.
- **Runs are serialised.** A `concurrency` group on `github.ref` stops two merges applying
  at once, with `cancel-in-progress: false` so an in-flight apply is never killed halfway.
- **`validate` needs no credentials**, so it passes on forks too.
- **Least privilege.** The workflow defaults to `contents: read`; only `plan` widens to
  `pull-requests: write` and `id-token: write`.

### Repository configuration

| Kind | Name | Value |
|---|---|---|
| Secret | `AZURE_CLIENT_ID` | OIDC federated app registration |
| Secret | `AZURE_TENANT_ID` | Directory the app registration lives in |
| Secret | `AZURE_SUBSCRIPTION_ID` | Target subscription |
| Variable | `TFSTATE_RESOURCE_GROUP` | `rg-tfstate` |
| Variable | `TFSTATE_STORAGE_ACCOUNT` | The storage account created above |
| Variable | `TFSTATE_CONTAINER` | `tfstate` |

Grant the CI service principal `Storage Blob Data Contributor` on the state container, or
its `terraform init` cannot reach the backend. Authentication is OIDC federated credentials
throughout — no client secret is stored.

Two caveats, stated rather than buried. Trivy runs twice: once reporting `HIGH,CRITICAL`
for visibility, once failing the build on `CRITICAL` only — tighten the gate to `HIGH` once
the backlog stays clear. And a saved plan file embeds resource attributes and is
downloadable by anyone with repository read access, so artefact retention is one day.

---

## Security posture

| Concern | Control |
|---|---|
| Registry credentials | ACR admin user disabled — no password exists to leak or rotate |
| Image pull authentication | User-assigned managed identity with `AcrPull`, scoped to this registry alone |
| CI to Azure authentication | OIDC federated credentials; no client secret stored |
| Terraform state authentication | Azure AD (`use_azuread_auth`), not a storage account key |
| State at rest | Public blob access disabled, TLS 1.2 minimum, blob versioning enabled |
| Unreviewed infrastructure change | `production` environment gate, and the apply runs the reviewed plan file |
| Concurrent conflicting applies | Workflow `concurrency` group plus state locking |
| Accidental resource group deletion | `prevent_deletion_if_contains_resources` |
| Misconfiguration drift | `fmt`, `validate`, TFLint and Trivy on every pull request |
| Runaway ingestion spend | `log_daily_quota_gb` |
| Silently stale deploys | Mutable image tags rejected at plan time |
| Secrets in the repo | `.gitignore` covers `*.tfvars`, `*.tfstate`, `backend.hcl` and `.terraform/` |

---

## Cost

Indicative only — check the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/)
for your region and usage.

| Component | Billing basis | Typical dev cost |
|---|---|---|
| Container Apps | Consumption (vCPU-seconds and GiB-seconds), with a monthly free grant | ≈ £0 at `min_replicas = 0` and light traffic |
| Container Registry (Basic) | Flat rate per registry | ≈ £4 / month |
| Log Analytics | Per GB ingested | Pennies at real volumes |
| Public IP / ingress | Included in Container Apps | — |

The `log_daily_quota_gb` default of 1 GB/day is a **ceiling, not an expectation** — a
model-serving API typically produces a few MB a day. It exists so a log-storm bounds out
at roughly £60/month instead of running unbounded; lower it if you want a tighter bound.

Destroy the stack when you are finished with it regardless.

---

## Troubleshooting

**`terraform init` fails with a 403 or `AuthorizationPermissionMismatch` on the state
container.** The identity is missing `Storage Blob Data Contributor`. Subscription Owner
does not grant data-plane access to blobs; the role has to be assigned explicitly.

**The revision will not start and events show an image pull failure.** Check
`terraform output bootstrap_mode`. If it is `false`, confirm the tag actually exists in the
registry (`az acr repository show-tags --name <acr> --repository <image>`). If the tag is
there, the `AcrPull` assignment may still be propagating — wait a minute and re-apply.

**`Saved plan is stale`.** State changed between the plan and the approval. Re-run the
workflow so a fresh plan is reviewed; this is the guard working, not a bug.

**First request after idle is slow.** `min_replicas = 0` means the platform scaled to zero
and is cold-starting a replica, including reloading the model. Set `min_replicas = 1`.

**`Unsupported cpu/memory pair`.** Container Apps requires exactly 2 GiB of memory per
vCPU. Valid pairs are listed in the error and in `terraform.tfvars.example`.

**A second registry appeared.** The registry name carries a `random_string` suffix. If
state is lost and re-created, that suffix is regenerated and Terraform builds a new
registry rather than adopting the old one. Recover the state file (blob versioning is
enabled for exactly this) instead of re-initialising from scratch.

---

## Verification status

Verified as far as is possible without an Azure subscription attached. Run against
**Terraform 1.9.8**, the version CI pins.

| Check | Result |
|---|---|
| `terraform fmt -check -recursive` | ✅ Clean |
| `terraform init -backend=false` | ✅ azurerm v3.117.1, random v3.9.0 |
| `terraform validate` | ✅ `Success! The configuration is valid.` |
| Variable validations | ✅ Every rule exercised via `terraform console` — bad cpu/memory pair, `image_tag=latest`, `min_replicas > max_replicas`, zero quota and sub-30-day retention are each rejected with the intended message |
| Bootstrap switching | ✅ Both branches confirmed: unset tag → placeholder on port 80 with probes off; tag set → registry image on 8000 with probes on |
| TFLint v0.64.0 + azurerm ruleset 0.32.0 | ✅ Zero findings |
| Trivy config scan | ✅ Zero misconfigurations at `HIGH` or `CRITICAL` |
| `terraform init -backend-config=…` | ◐ Backend arguments accepted; authentication not reachable on the verifying machine (no Azure CLI installed) |
| `terraform plan` | ⏳ Requires Azure credentials — run it yourself |
| `terraform apply` | ⏳ Not run; creates billable resources |

`validate` confirms the syntax, provider schema and resource arguments are correct — every
attribute here exists on the azurerm provider and is used correctly. It does not confirm
that the deployment succeeds; only `plan` and `apply` against a real subscription do that.

To finish verifying:

```bash
az login
cd terraform
terraform init -backend-config=backend.hcl
terraform plan
```

---

## Limitations

Stated plainly, because a README that only lists strengths is not a useful engineering
document.

- **Single environment, single region.** `environment` keeps `dev` and `prod` names from
  colliding, but there is no multi-region topology and no traffic manager in front.
- **No landing zone.** No management groups, Azure Policy, budgets or subscription
  vending. The only guardrail is the log ingestion cap.
- **Public ingress.** The registry and app are reachable over the internet. Private
  endpoints and VNet integration require a Premium registry and a workload profiles
  environment.
- **No canary or blue/green.** `revision_mode = "Single"` sends 100% of traffic to the
  latest revision. Weighted traffic splitting needs `Multiple` mode and a revision-aware
  deploy step.
- **No model-specific observability.** Container logs and platform metrics are routed;
  prediction latency histograms, drift detection and data-quality monitoring are not.
- **CI deploys infrastructure, not models.** Image build and push live in the application
  repository. The path from a new image to a running revision is one `terraform apply` with
  a new tag, run deliberately rather than automatically.

It is the deployment layer for one model-serving service, which is what it claims to be.
