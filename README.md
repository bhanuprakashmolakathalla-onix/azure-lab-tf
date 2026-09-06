# azure-lab-tf

An Azure Databricks lakehouse platform, built as infrastructure-as-code from an empty
subscription. Six Terraform root modules, two environments, a medallion pipeline, and a
CI/CD pipeline that deploys all of it with **no stored credentials**.

Running cost when idle: **~₹10/month**. Total cost to build: **~₹40**.

---

## What it provisions

```
Azure subscription
├── rg-terraform-state/              state backend (bootstrapped imperatively, once)
│   └── sttfstatebhanu7391           versioned, shared keys DISABLED, Entra auth only
│
└── rg-lab01-foundation/
    ├── stdatalakebhanu7391          ADLS Gen2, hierarchical namespace
    │   ├── landing/                 Auto Loader source
    │   ├── bronze/ silver/ gold/    medallion layers (external locations)
    │   ├── managed-dev/             dev catalog's managed storage
    │   ├── managed-prod/            prod catalog's managed storage
    │   └── checkpoints/             Auto Loader schema + commit state
    │
    ├── dbac-lab01-uc                Access Connector (managed identity for UC)
    ├── dbw-lab01-dev                Databricks workspace
    └── dbw-lab01-prod               Databricks workspace

Unity Catalog (account-level, region-wide, survives every teardown)
├── sc-lab01-adls                    storage credential -> Access Connector
├── el-lab01-*                       7 external locations
├── dev  (ISOLATED)                  bronze / silver / gold
└── prod (ISOLATED)                  bronze / silver / gold
```

## Module layout

Each directory is a **root module with its own state file**. They read each other through
`terraform_remote_state`, never through a shared state file.

| Module | State key | Owns |
|---|---|---|
| `foundation` | `foundation.tfstate` | resource group, ADLS Gen2, containers, Access Connector, data-plane RBAC |
| `workspace` | `workspace.tfstate` | both Databricks workspaces (`for_each`) |
| `unity-catalog` | `unity-catalog.tfstate` | storage credential, external locations, catalogs, schemas, groups, grants, bindings |
| `jobs` | `jobs.tfstate` | notebooks and the medallion job, per environment |
| `compute` | `compute.tfstate` | cluster policy + an all-purpose cluster for ad-hoc work |
| `governance` | `governance.tfstate` | subscription budget and alerts |

**Why separate state files rather than one?** Blast radius. A `terraform destroy` in `compute`
physically cannot reach the lake, because the lake is not in that state file. The cost is
losing a single `apply`; the benefit is that a bad day stays contained.

`governance` is separate for a different reason: subscription guardrails must **outlive** a
teardown of the lab. A budget that disappears with the resources it was watching is worse
than no budget.

## Getting it running

Two bootstraps come first, both imperative, both for the same reason — Terraform cannot
create the thing it depends on to run.

```powershell
.\bootstrap-backend.ps1          # state storage. Terraform needs somewhere to keep state.
.\bootstrap-ci-identity.ps1      # the SP that runs Terraform. It cannot create itself.
.\bootstrap-github-oidc.ps1 -GitHubOwner <you> -GitHubRepo azure-lab-tf -OwnerId <id> -RepoId <id>
```

Then, in dependency order:

```powershell
cd foundation     ; terraform init ; terraform apply
cd ../workspace   ; terraform init ; terraform apply
cd ../unity-catalog ; terraform init ; terraform apply
cd ../jobs        ; terraform init ; terraform apply
cd ../governance  ; terraform init ; terraform apply
```

About 15 minutes from an empty subscription. `compute` is optional and costs money while it
runs.

## CI/CD

`.github/workflows/terraform.yml` — pull requests **plan**, merges to `main` **apply**.
Applies the reviewed plan file, never a fresh plan, so what runs is exactly what was
approved.

`.github/workflows/drift.yml` — nightly `plan` across every module. Opens one GitHub issue
per drifted module, reuses it rather than creating duplicates, and closes it when the module
comes back clean.

**Authentication is entirely secretless.** GitHub mints a short-lived OIDC token, Entra is
configured to trust that specific repository and ref, and the service principal has no
password at all. Nothing long-lived exists to leak.

## The security model

Four independent gates, each enforced by a different subsystem, each failing differently:

| Gate | Question | Failure looks like |
|---|---|---|
| **Identity** | does this principal exist? | not found |
| **Assignment** | may it enter this workspace? | cannot log in |
| **Binding** | is this catalog reachable from here, and in which direction? | "catalog does not exist" |
| **Grants** | what may it touch once inside? | "permission denied" |

Concretely:

- `dev` and `prod` catalogs are `ISOLATED` and bound to their own workspace. `prod` is
  additionally bound `READ_ONLY` to the dev workspace — dev can read production, and writes
  from there are structurally impossible, not merely un-granted.
- The asymmetry is deliberate: `prod` grants dev nothing back, so production cannot come to
  depend on dev data by accident.
- **No human can write to `prod`.** The only principal with `MODIFY` is the service
  principal, and the jobs run as it. Production changes arrive through a reviewed pipeline.
- Unity Catalog objects are owned by the **`platform-admins` group**, never by a person.

## The pipeline

`samples.nyctaxi` → `landing/` → **bronze** → **silver** → **gold**, running as the service
principal on a single shared job cluster.

- **bronze** — Auto Loader (`cloudFiles`) with `trigger(availableNow=True)`. Incremental:
  cost is proportional to what arrived, not to total history. Schema and commit checkpoints
  live in separate directories because they have different blast radii.
- **silver** — business rules are **named**, and failing rows go to a quarantine table with
  the list of rules they broke, rather than being silently dropped.
- **gold** — daily aggregates, shaped for a consumer.

## Cost engineering

Measured, not assumed — `analysis/cost_attribution.sql` has the queries.

| SKU | $/DBU |
|---|---|
| `PREMIUM_ALL_PURPOSE_COMPUTE` | 0.550 |
| `PREMIUM_JOBS_SERVERLESS_COMPUTE` | 0.470 |
| `PREMIUM_JOBS_COMPUTE` | **0.300** |

All-purpose compute costs **1.83× job compute for identical hardware**. One interactive
cluster used for a few queries cost more than every pipeline run of the fortnight combined.

Decisions that mattered more than the numbers:

- **`no_public_ip = false`** on the workspaces. Secure cluster connectivity provisions a NAT
  gateway billing ~₹100/day whether or not anything runs. Turning it off took idle cost from
  ~₹3,000/month to ~₹10/month. Wrong for production, right for a lab torn down nightly.
- **One job cluster shared across all tasks.** Measured: 351s of cold start paid once, then
  1s per subsequent task. Per-task clusters would have paid it three times for 63s of work.
- **Ask for a node *shape*, not a SKU.** `data "databricks_node_type"` with `min_cores` lets
  Databricks route around regional capacity stockouts. Quota is not capacity.

## Things that cost time, documented so they cost yours less

- **Owner grants no data access.** Azure splits `actions` (control plane) from `dataActions`
  (data plane), and the built-in Owner role has `dataActions: []`. `roles/owner` in GCP does
  cover object access; this is the sharpest false friend in the mapping.
- **HNS and blob versioning are mutually exclusive.** Delta's transaction log is the
  replacement, and it is the better tool anyway — versioning per table, not per blob.
- **Azure propagates workspace resource tags onto clusters as *default* tags.** Setting the
  same tag in a cluster policy collides with the inherited one and cluster creation fails.
  The upside: cost attribution by tag works with no cluster-level tagging at all.
- **The `databricks` provider cannot live in the module that creates its own workspace** —
  its `host` is the workspace URL, and provider blocks evaluate before any resource exists.
  The module split is what makes the reference legal.
- **A variable may change what a resource looks like, never which provider manages it.**
  State records which workspace each object belongs to; repointing a provider under populated
  state is incoherent, and the provider correctly refuses.
- **An account-level group is invisible inside a workspace until it is *assigned* there.**
  Transferring object ownership to an unassigned group succeeds and then locks out every
  principal at once.
- **`databricks_grants` is authoritative.** It declares the complete privilege set and
  silently revokes anything granted outside Terraform.
- **`databricks_job` task blocks are a positional list**, and the API returns them sorted
  alphabetically. Config must match that order or every plan shows a diff that applies
  successfully and immediately returns.
- **`az` on Windows is a `.cmd` shim**, so `( ) < > | & ^` are live cmd metacharacters even
  inside PowerShell quotes. Keep JMESPath function calls out of `--query`.

## Repository

```
bootstrap-*.ps1              one-time, imperative, deliberately outside Terraform
foundation/ workspace/ unity-catalog/ jobs/ compute/ governance/
jobs/modules/pipeline/       reusable pipeline, instantiated per environment
unity-catalog/modules/catalog/  reusable catalog, instantiated per environment
analysis/cost_attribution.sql
.github/workflows/
```

Both child modules are instantiated **twice** with different provider aliases, because
Terraform cannot select a provider from a `for_each` key. That constraint is useful: it forces
the provider choice to be explicit and reviewable in the diff.
