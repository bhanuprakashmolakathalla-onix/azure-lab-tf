# azure-lab-tf

A private Azure Databricks lakehouse, built as infrastructure-as-code from an empty
subscription, with two websites on top of it: a **storefront** people buy from and an
**operations console** somebody runs the business from.

Nine Terraform root modules, a medallion pipeline over generated fashion-retail data,
and CI that deploys the Azure half with **no stored credentials**.

The point of the pair is that they meet in the lakehouse. The shop writes an order to
`fashion.ops.orders`; the console reads it seconds later, works it through picking and
shipping, and shows the trading figures the same warehouse produced. Nothing is mocked
between them.

---

## What it builds

```
Azure subscription
├── rg-terraform-state/              state backend (bootstrapped imperatively, once)
│   └── sttfstatebhanu7391           versioned, shared keys DISABLED, Entra auth only
│
├── rg-lab01-transit/                humans and the apps
│   ├── vnet-transit 10.10.0.0/16
│   │   ├── snet-privatelink         front-end + browser-auth private endpoints
│   │   ├── snet-jumpbox             the only way in
│   │   └── snet-apps /23            Container Apps, VNet-injected
│   ├── vm-jumpbox                   RDP from one address only
│   └── privatelink.azuredatabricks.net   FRONT-END zone
│
├── rg-lab01-network/                clusters
│   ├── vnet-databricks 10.20.0.0/16
│   │   ├── snet-host / snet-container    delegated, no public IPs
│   │   └── snet-privatelink              back-end + storage endpoints
│   ├── nat-databricks               single egress address
│   └── privatelink.azuredatabricks.net   BACK-END zone (same name, different RG)
│
├── rg-lab01-foundation/
│   ├── stdatalakebhanu7391          ADLS Gen2, HNS, firewall deny-by-default
│   │   └── landing/ bronze/ silver/ gold/ checkpoints/ managed/
│   ├── dbac-lab01-uc                Access Connector (managed identity for UC)
│   └── dbw-fashion                  Databricks workspace, no public path in or out
│
└── rg-lab01-serving/
    ├── acrfashionbhanu7391          Basic by default, admin access disabled
    ├── id-fashion-shop              storefront identity
    ├── id-fashion-console           console identity
    ├── ca-fashion-shop              the shop
    └── ca-fashion-console           the ops console

Unity Catalog (account-level, region-wide, survives every teardown)
├── sc-lab01-adls                    storage credential -> Access Connector
├── el-lab01-*                       6 external locations
└── fashion (ISOLATED)               bronze / silver / gold / ops
```

## Module layout

Each directory is a **root module with its own state file**. They read each other through
`terraform_remote_state`, never through a shared state file.

| Module | State key | Owns | Runs from |
|---|---|---|---|
| `infra/network` | `network.tfstate` | VNets, subnets, NSG, NAT gateway, private DNS, peering | anywhere |
| `infra/foundation` | `foundation.tfstate` | resource group, ADLS Gen2, containers, storage endpoints, Access Connector, data-plane RBAC | anywhere |
| `infra/workspace` | `workspace.tfstate` | the Databricks workspace and its three private endpoints | anywhere |
| `infra/governance` | `governance.tfstate` | subscription budget and alerts; the CI principal's Databricks identity | anywhere |
| `infra/jumpbox` | `jumpbox.tfstate` | the VM that is the only way into the private network | anywhere |
| `infra/compute` | `compute.tfstate` | cluster policy + an ad-hoc cluster. Optional, and bills while it runs | **jumpbox** |
| `data/catalog` | `unity-catalog.tfstate` | storage credential, external locations, catalog, schemas, groups, grants, bindings | **jumpbox** |
| `data/pipelines` | `jobs.tfstate` | notebooks and the medallion job | **jumpbox** |
| `app/deploy` | `serving.tfstate` | registry, both container apps, both identities, SQL warehouse, app grants | **jumpbox** |

**The state keys do not all match their directory names.** `data/catalog` writes
`unity-catalog.tfstate`, `data/pipelines` writes `jobs.tfstate`, and `app/deploy` writes
`serving.tfstate`. Those are the names from before the restructure and they were kept
deliberately: renaming a state key does not move the state, it orphans it.

**Why separate state files rather than one?** Blast radius. A `terraform destroy` in
`compute` physically cannot reach the lake, because the lake is not in that state file.
The cost is losing a single `apply`; the benefit is that a bad day stays contained.

`governance` is separate for a different reason: it holds what must **outlive** a teardown.
A budget that vanishes with the resources it was watching is worse than no budget, and the
service principal that *runs* Terraform must not be owned by state that Terraform destroys.

## Getting it running

Three bootstraps first, all imperative, all for the same reason — Terraform cannot create
the thing it depends on to run.

```powershell
.\infra\bootstrap\bootstrap-backend.ps1       # state storage
.\infra\bootstrap\bootstrap-ci-identity.ps1   # the SP that runs Terraform
.\infra\bootstrap\bootstrap-github-oidc.ps1 -GitHubOwner <you> -GitHubRepo azure-lab-tf -OwnerId <id> -RepoId <id>
```

> `bootstrap-ci-identity.ps1` mints a **one-year client secret** so you can run Terraform as
> the service principal before federation exists. The OIDC script prints the `az` command to
> delete it and does not run it for you. Until you do, the repo's secretless claim is one
> manual step short of true.

Then, in dependency order. The first four reach ARM over the public internet and run anywhere:

```powershell
cd infra\network     ; terraform init ; terraform apply
cd ..\foundation     ; terraform init ; terraform apply
cd ..\workspace      ; terraform init ; terraform apply
cd ..\governance     ; terraform init ; terraform apply
cd ..\jumpbox        ; terraform init
# Detects your public address rather than asking you to paste one. Both values
# are validated at plan time, so a placeholder fails immediately instead of
# becoming a firewall rule for an address that cannot exist.
$ip = (Invoke-RestMethod https://api.ipify.org).Trim()
terraform apply -var="allowed_source_ip=$ip" -var="admin_password=<a 12+ char password, 3 of: lower upper digit symbol>"
```

Everything after this point talks to the Databricks workspace, whose hostname resolves
only inside the transit or workspace VNet. **RDP to the jumpbox, clone the repo there, and
continue:**

```powershell
cd data\catalog      ; terraform init ; terraform apply
cd ..\pipelines      ; terraform init ; terraform apply
# run the fashion-medallion job once, so gold has something in it
cd ..\..\app         ; az acr build --registry <acr> --image fashion-app:v1 .
cd deploy            ; terraform init ; terraform apply
```

`terraform output shop_url` and `terraform output console_url` are the two links.

### Tearing it down

```powershell
.\infra\bootstrap\teardown.ps1 -Scope All        # correct, ~12 minutes
.\infra\bootstrap\teardown.ps1 -Scope All -Fast  # ~4 minutes, empties state
```

Order is not negotiable and is why this is a script. The Databricks modules go first,
because they own account-level objects that live in **no resource group** — groups, service
principals, the storage credential and its external locations. Delete the resource groups
first and those are orphaned, invisible, and waiting to collide with the next rebuild. The
jumpbox goes after them, because destroying your way in locks you out of the rest.

**Measured by actually doing it**, on the previous build:

| | |
|---|---|
| Teardown — 4 modules, 64 resources | **12m41s** |
| Rebuild from empty — 4 modules, ~70 resources | **~15 min** |

## A session, end to end

The lab is designed to be built, used, and destroyed the same day. The whole loop:

1. **Build the Azure half** from the laptop — network, foundation, workspace, governance,
   jumpbox. Roughly 15 minutes, most of it the workspace and its private endpoints.
2. **RDP to the jumpbox** and build the Databricks half — catalog, pipelines, then the image
   and the two sites.
3. **Run `fashion-medallion` once.** Nothing has a catalogue until gold exists. The seed task
   pays a one-off cluster cold start of about six minutes; the other three tasks are seconds.
4. **Open both links.** Browse, add to bag, check out. The order appears in the console's
   order book within a few seconds. Advance it through packed and shipped, or cancel it and
   watch the stock come back on the product page.
5. **Tear down in two halves, from two machines.** The Databricks stage runs on the jumpbox
   because it is the only thing that can reach the workspace. The Azure stage must not,
   because it deletes the jumpbox out from under itself:

   ```powershell
   # on the jumpbox
   .\infra\bootstrap\teardown.ps1 -Scope Databricks
   # back on the laptop
   .\infra\bootstrap\teardown.ps1 -Scope Azure -Fast
   ```

The single most expensive mistake available here is stopping after step 4.

## The two sites

One container image, two container apps, selected by `APP_ROLE`. The code is shared
because it is the same code; the **identities are not**, because the privileges are not.

| | `gold` | `silver` | `ops` |
|---|---|---|---|
| `id-fashion-shop` | read | — | read, write, create |
| `id-fashion-console` | read | read | read, write |

The shop can take an order and cannot look at the silver layer. The console can see
everything the pipeline produced, including what it quarantined, and cannot create a
table. Neither holds a secret.

**The storefront** browses a catalogue, filters by colour and size, shows markdown against
list price, greys out sold-out sizes, and takes an order. No payment is collected. Product
imagery is drawn as vector garments tinted with each product's real colour — a remote image
CDN would be a hole in the network posture for the sake of decoration, and no photograph of
a generated product exists anyway.

The fit note on every product page is the most interesting thing on it: it reads
`gold.returns_analysis`, a mart built for merchandisers, and turns it into a sentence a
shopper can act on. Every retailer knows why its returns happen and almost none of them
tell you before you buy.

**The console** works the order book, advances fulfilment status with `UPDATE` statements
against Delta, and shows trading, inventory health and the silver quarantine counts.

### Why browsing never queries the warehouse

The catalogue is a few hundred rows that change only when the pipeline runs, so it is
loaded **once** and held in the process. Browsing, filtering, sorting and product pages
touch nothing. The warehouse is woken only by checkout and by the console.

The cache is stale-tolerant rather than merely time-limited: when an entry expires the page
still renders from the old value and a background thread fetches the new one. A shopper
never waits on a refresh. A serverless warehouse bills while it is *running*, so a shop that
queried on every page view would keep it running all day and still feel slow.

### What the shop deliberately does not do

Stock shown is the last pipeline snapshot minus orders placed since. **It is not a
reservation system.** Two shoppers can buy the last unit at the same time and both succeed.
A real storefront holds stock in a transactional store at add-to-bag time; a lakehouse
snapshot cannot do that and should not pretend to.

The same honesty applies to the order book itself. Delta is a poor transactional store —
every insert is a new commit and a new file. A real business writes orders to Postgres or
Cosmos DB and lands them here by change data capture. At a handful of orders in a sitting
the direct write is fine, and it is what makes the write-path identity gates visible end to
end.

## CI/CD

`.github/workflows/terraform.yml` — pull requests **plan**, merges to `main` **apply**.
Applies the reviewed plan file, never a fresh plan, so what runs is exactly what was
approved.

`.github/workflows/drift.yml` — nightly `plan` across every module CI can reach. Opens one
GitHub issue per drifted module, reuses it rather than creating duplicates, and closes it
when the module comes back clean.

**CI covers the four `azurerm` modules only.** `data/*`, `app/deploy` and `infra/compute`
use the `databricks` provider, whose host is the workspace URL — and since
`public_network_access_enabled = false`, that name resolves only inside the VNet. A
GitHub-hosted runner is on Microsoft public infrastructure, outside both. Those modules
cannot run there: not slowly, not with a token, not at all. The real fix is a self-hosted
runner inside the VNet, which is exactly why regulated organisations run their own runner
fleets.

**Authentication is secretless.** GitHub mints a short-lived OIDC token, Entra is configured
to trust that specific repository and ref, and the federated credential uses the immutable
`repo:OWNER@ID/REPO@ID:` subject format that cannot be claimed by a recycled repository name.

## The security model

Four independent gates, each enforced by a different subsystem, each failing differently:

| Gate | Question | Failure looks like |
|---|---|---|
| **Identity** | does this principal exist? | not found |
| **Assignment** | may it enter this workspace? | cannot log in |
| **Binding** | is this catalog reachable from here, and in which direction? | "catalog does not exist" |
| **Grants** | what may it touch once inside? | "permission denied" |

Concretely:

- The `fashion` catalog is `ISOLATED` and bound to one workspace. A metastore is
  **region-wide**, so any workspace attached later would otherwise see every `OPEN` catalog
  by default. The failure this prevents is somebody else's future workspace, not yours.
- Unity Catalog objects are owned by the **`platform-admins` group**, never by a person.
  Whoever creates a UC object owns it, and a person leaving makes their objects unmanageable.
- Analysts hold `USE_CATALOG` at the catalog and `SELECT` only on `gold`. A catalog-level
  `SELECT` would cascade to every schema added from now on, including `ops`.
- Jobs run as the **service principal**, not as a person, and binding a principal to
  `run_as` is a separate right from workspace admin.

### One thing that was wrong here, and is worth the paragraph

`databricks_grants` (plural) is **authoritative**: it declares the complete privilege set
for a securable and revokes anything absent. `data/catalog` used it on the `fashion`
catalog while `app/deploy` granted the app identities on the same catalog with
`databricks_grant` (singular). Every apply of the catalog module silently revoked the apps'
access, and the sites started reporting that `gold` did not exist — both modules reporting
success, neither converging.

Two modules granting on one securable means the **singular** form in both. The cost is
real and stated in the code: nothing declares the complete set any more, so a privilege
granted by hand in the UI will survive. That is the trade for shared ownership, and drift
detection is what covers it.

## The pipeline

Generated drops → `landing/` → **bronze** → **silver** → **gold**, running as the service
principal on a single shared job cluster.

- **seed** — fakes the upstream systems a fashion retailer has: POS, warehouse and returns
  dropping dated JSON files, plus a full product and store snapshot. Deterministic, so a
  pipeline bug is distinguishable from a data change. The data has three properties generic
  retail examples miss: a **size curve**, **markdown decay**, and **category-dependent
  return rates**.
- **bronze** — Auto Loader (`cloudFiles`) with `trigger(availableNow=True)`. Incremental:
  cost is proportional to what arrived, not to total history. Anything that does not fit the
  schema lands in `_rescued_data` rather than being dropped.
- **silver** — business rules are **named**, and failing rows go to a quarantine table with
  the list of rules they broke. A non-null `_rescued_data` is one of those rules, in every
  stream. Returns are netted off sales here, once, so no downstream table has to remember.
- **gold** — seven marts. Five answer a merchandising question; two serve the storefront at
  the grain a shopper thinks in, sized to fit in the app's memory.

## Cost

Measured DBU rates, from `data/analysis/cost_attribution.sql`:

| SKU | $/DBU |
|---|---|
| `PREMIUM_ALL_PURPOSE_COMPUTE` | 0.550 |
| `PREMIUM_JOBS_SERVERLESS_COMPUTE` | 0.470 |
| `PREMIUM_JOBS_COMPUTE` | **0.300** |

All-purpose compute costs **1.83× job compute for identical hardware**. One interactive
cluster used for a few queries cost more than every pipeline run of a fortnight combined.

### What it costs to stand still

Rates below are Central India retail, pulled from the Azure retail price API rather than
estimated. They are what the platform charges **for existing**, whether or not anything runs:

| Resource | Count | ₹/hour |
|---|---|---|
| Jumpbox `Standard_E4bs_v5`, Windows | 1 | 47.20 |
| Private endpoints | 5 | 4.78 |
| NAT gateway | 1 | 4.30 |
| Jumpbox OS disk, Premium P10 | 1 | 2.58 |
| Public IPs, Standard static | 2 | 0.96 |
| Container registry, Basic | 1 | 0.66 |
| **Standing total** | | **60.48** |

The five private endpoints are the price of the private architecture: two for storage
(`dfs` and `blob`) and three for the workspace (back-end, front-end, browser auth). They are
not optional if the workspace has no public path.

Left running for a day that is **₹1,452**, which eats a ₹15,000 monthly budget in ten days.
Deallocating the jumpbox drops it to **₹13.28/hour**, or ₹319/day — still ₹9,500 a month for
a lab nobody is using. The teardown script is the only real control.

### What it costs to do something

| Resource | Rate | Lever |
|---|---|---|
| Serverless SQL warehouse, 2X-Small | ₹294/hour running (4 DBU × ₹73.57) | `warehouse_auto_stop_mins`, and the in-process catalogue cache |
| Job cluster, single-node `D4ds_v5` | ₹52/hour (₹23.31 VM + ~1 DBU × ₹28.66) | runs only while the job runs |
| Container Apps | ~₹0 | `min_replicas = 0`, and the monthly free grant covers a session |
| Log Analytics, storage, state | ~₹0 | below the free grants at this volume |

One number there is an assumption rather than a quote: `Standard_D4ds_v5` is taken as 1.0
DBU/hour. Everything else is a published rate.

### A build, a session, a teardown

Three hours of wall clock, one pipeline run, fifteen minutes of clicking:

| | ₹ |
|---|---|
| Standing cost, 3 hours | 181 |
| Pipeline run, ~15 min | 13 |
| SQL warehouse, ~25 min awake | 123 |
| **Total** | **~320** |

The warehouse is awake longer than you are clicking because of the ten-minute auto-stop tail.
That tail is deliberate: restarting on every request costs more in patience than it saves in
rupees. The catalogue cache is what keeps browsing from extending it.

Switching `serving_compute` to `"cluster"` cuts the compute rate to about a quarter, and is
still usually the worse deal for a short session: it has to stay up through a twenty-minute
idle timeout while a serverless warehouse bills only while a query is in flight.

Decisions that mattered more than the numbers:

- **The catalogue cache.** It is a cost control, not a performance trick. Browsing that
  queried the warehouse would keep a serverless SKU awake continuously.
- **One job cluster shared across all tasks.** Measured: 351s of cold start paid once, then
  1s per subsequent task. Per-task clusters would have paid it four times for a minute of work.
- **Ask for a node *shape*, not a SKU** — except when you cannot. `data "databricks_node_type"`
  routes around regional stockouts, but it has no visibility into your quota and will happily
  return a SKU you are not permitted to allocate. Both pipeline and compute now pin the type.

## Things that cost time, documented so they cost yours less

- **Owner grants no data access.** Azure splits `actions` (control plane) from `dataActions`
  (data plane), and the built-in Owner role has `dataActions: []`. `roles/owner` in GCP does
  cover object access; this is the sharpest false friend in the mapping.
- **Two ways to close a storage account, and only one leaves Unity Catalog working.**
  `public_network_access_enabled = false` kills the endpoint outright and breaks credential
  validation, which runs from the Databricks **control plane** outside your VNet.
  `network_rules` with `default_action = Deny` plus a `private_link_access` exception for
  the Access Connector is what production actually runs.
- **A private endpoint with no `private_dns_zone_group` resolves to nothing.** The endpoint
  exists, holds an IP, and every client still gets the public address.
- **Two same-named private DNS zones, in two resource groups.** Front-end and back-end
  endpoints target the same sub-resource and therefore the same hostname, but a user and a
  cluster must resolve it to different addresses. Zone names are unique per resource group,
  so the split is what makes the architecture expressible at all.
- **The browser-authentication endpoint is the one everybody forgets.** Sign-in redirects to
  Entra, which calls back to the Databricks web app; with no public path the callback cannot
  land and login spins forever, looking like a broken workspace.
- **Attaching a private endpoint updates the workspace**, and the API rejects concurrent
  updates with `ConcurrentUpdateError`. Terraform parallelises to 10 and nothing in the
  config says these three conflict. A `depends_on` chain is the fix.
- **HNS and blob versioning are mutually exclusive.** Delta's transaction log is the
  replacement, and it versions per table rather than per blob.
- **Azure propagates workspace resource tags onto clusters as *default* tags.** Setting the
  same tag in a cluster policy collides with the inherited one and cluster creation fails.
- **The `databricks` provider cannot live in the module that creates its own workspace** —
  its `host` is the workspace URL, and provider blocks evaluate before any resource exists.
- **A variable may change what a resource looks like, never which provider manages it.**
- **An account-level group is invisible inside a workspace until it is *assigned* there.**
  Transferring object ownership to an unassigned group succeeds and then locks out every
  principal at once.
- **`databricks_job` task blocks are a positional list**, and the API returns them sorted
  alphabetically. Config must match that order or every plan shows a diff that applies
  successfully and immediately returns.
- **`databricks_service_principal` does not round-trip.** Its SCIM delete DEACTIVATES the
  account record instead of removing it, so destroy-then-recreate collides with "already
  exists". The fix is structural: an identity that *runs* Terraform belongs outside the
  state Terraform destroys.
- **`CAN_ATTACH_TO` fails when both ends are elastic.** The app scales to zero and the
  cluster auto-terminates, so by the time a request arrives there is nothing running to
  attach to — the caller needs `CAN_RESTART` to start it.
- **Null is not a small case.** `days_of_cover` is null when nothing sold, every comparison
  against null is null, and dead stock fell through to `otherwise("healthy")`. The single
  worst state in the inventory was reported as the best one.
- **`az` on Windows is a `.cmd` shim**, so `( ) < > | & ^` are live cmd metacharacters even
  inside PowerShell quotes. Keep JMESPath function calls out of `--query`.

## Repository

```
infra/bootstrap/         one-time, imperative, deliberately outside Terraform
                         plus teardown.ps1, which is the most important script here
infra/                   network, foundation, workspace, governance, jumpbox, compute
data/catalog/            Unity Catalog: credential, locations, catalog, grants
data/pipelines/          the medallion job and its four notebooks
data/analysis/           cost attribution and Delta operations, as SQL you paste into a cell
app/src/                 both sites: db, cart, imagery, theme, charts, shop, console
app/deploy/              registry, two container apps, two identities, SQL warehouse
.github/workflows/
```
