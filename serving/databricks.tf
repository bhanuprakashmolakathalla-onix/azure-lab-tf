# The Databricks half of the serving tier: somewhere to run the query, and an
# identity permitted to run it.

# --- SQL warehouse --------------------------------------------------------
#
# A warehouse, not an all-purpose cluster. Different product for a different
# job: warehouses start in seconds, are optimised for concurrent short queries,
# and scale independently of any notebook workload.
#
# 2X-SMALL, deliberately. The auto-provisioned "Serverless Starter Warehouse" is
# Small - 12 DBU/hour against 4 - so three times the cost for a query returning
# thirty rows. Warehouse sizing is the largest cost lever in Databricks SQL and
# the default is rarely the right answer.
#
# SERVERLESS because start-up matters here. A classic warehouse takes minutes to
# come up; serverless takes seconds, which is the difference between an API that
# feels broken after idling and one that feels slow for a moment.
resource "databricks_sql_endpoint" "serving" {
  provider = databricks.dev
  count    = var.serving_compute == "warehouse" ? 1 : 0

  name                      = "wh-serving-2xs"
  cluster_size              = "2X-Small"
  enable_serverless_compute = true

  # Ten minutes. The warehouse bills only while RUNNING, so this is the single
  # number that decides whether an occasionally-used API costs Rs 50 a day or
  # Rs 6,000 a month. Lower is not automatically better - re-starting on every
  # request is its own kind of waste - but idle time is pure loss.
  auto_stop_mins = 10

  # One cluster. Scaling out serves concurrent users; there is one caller here.
  max_num_clusters = 1
  min_num_clusters = 1

  tags {
    custom_tags {
      key   = "purpose"
      value = "serving"
    }
    custom_tags {
      key   = "owner"
      value = "bhanu"
    }
  }
}

# --- The cheap alternative ------------------------------------------------
#
# A single-node all-purpose cluster serving the same query. Six-to-eight times
# cheaper per hour and about thirty-five times slower to start.
#
# data_security_mode SINGLE_USER pinned to the APP's identity: this cluster
# exists to serve one caller, and single-user mode is what gives it full Unity
# Catalog access under that principal. Nobody else can attach to it - which for
# a serving cluster is a feature.
resource "databricks_cluster" "serving" {
  provider = databricks.dev
  count    = var.serving_compute == "cluster" ? 1 : 0

  cluster_name  = "serving-taxi-api"
  spark_version = data.databricks_spark_version.lts.id
  node_type_id  = data.databricks_node_type.smallest.id
  num_workers   = 0

  # Twenty minutes. Longer than the warehouse's ten because the restart penalty
  # is ~6 minutes rather than ~10 seconds - the right idle timeout is a function
  # of how expensive it is to come back.
  autotermination_minutes = 20

  spark_conf = {
    "spark.databricks.cluster.profile" = "singleNode"
    "spark.master"                     = "local[*]"
  }

  custom_tags = {
    "ResourceClass" = "SingleNode"
  }

  data_security_mode = "SINGLE_USER"
  single_user_name   = azurerm_user_assigned_identity.app.client_id
}

data "databricks_node_type" "smallest" {
  provider      = databricks.dev
  local_disk    = true
  min_cores     = 4
  min_memory_gb = 8
  category      = "General Purpose"
}

data "databricks_spark_version" "lts" {
  provider          = databricks.dev
  long_term_support = true
}

# The HTTP path the connector uses. Warehouses and clusters expose different
# shapes, and this is the ONLY place the choice leaks into anything else.
locals {
  serving_http_path = var.serving_compute == "warehouse" ? (
    databricks_sql_endpoint.serving[0].odbc_params[0].path
    ) : (
    "/sql/protocolv1/o/${data.terraform_remote_state.workspace.outputs.workspace_ids["dev"]}/${databricks_cluster.serving[0].id}"
  )
}

# --- The app's identity, Databricks side ----------------------------------
#
# The managed identity's CLIENT ID is its application id in Entra, and that is
# the value Databricks registers. One identity, two directories, linked by that
# GUID - the same three-object shape as the CI principal on Day 5.
#
# NOTE for a future teardown: destroying this DEACTIVATES rather than deletes
# the account record (Day 15). It does not bite here the way it bit CI, because
# destroying this module also destroys the managed identity - so a rebuild
# produces a NEW client id and a fresh registration rather than colliding with
# the old one. The cost is an inactive record left behind per rebuild.
resource "databricks_service_principal" "app" {
  provider = databricks.account

  application_id = azurerm_user_assigned_identity.app.client_id
  display_name   = "sp-taxi-api"
}

# Gate 2: may it enter the workspace at all. USER, not ADMIN - it reads one
# table and needs nothing else.
resource "databricks_mws_permission_assignment" "app_dev" {
  provider     = databricks.account
  workspace_id = data.terraform_remote_state.workspace.outputs.workspace_ids["dev"]
  principal_id = databricks_service_principal.app.id
  permissions  = ["USER"]
}

# Gate 3: may it use this warehouse. Separate from data access entirely - a
# principal can hold SELECT on every table and still be unable to run a query,
# because compute permission and data permission are different systems.
resource "databricks_permissions" "warehouse" {
  provider        = databricks.dev
  count           = var.serving_compute == "warehouse" ? 1 : 0
  sql_endpoint_id = databricks_sql_endpoint.serving[0].id

  access_control {
    service_principal_name = azurerm_user_assigned_identity.app.client_id
    permission_level       = "CAN_USE"
  }

  depends_on = [databricks_mws_permission_assignment.app_dev]
}

# Same gate, cluster flavour - and the level matters more than it looks.
#
#   CAN_ATTACH_TO  use a cluster that is ALREADY RUNNING
#   CAN_RESTART    the above, plus start a terminated one
#   CAN_MANAGE     the above, plus edit and delete it
#
# CAN_ATTACH_TO is the intuitive least-privilege choice and it FAILS here, with
# "You do not have permission to autostart <cluster-id>". The app scales to zero
# and the cluster auto-terminates, so by the time a request arrives there is
# usually nothing running to attach TO - the caller has to be able to START it.
#
# This only bites when both ends are elastic. Against a permanently-running
# cluster, or a serverless warehouse (which has no start to authorise),
# CAN_ATTACH_TO would be correct and genuinely least-privilege.
resource "databricks_permissions" "cluster" {
  provider   = databricks.dev
  count      = var.serving_compute == "cluster" ? 1 : 0
  cluster_id = databricks_cluster.serving[0].id

  access_control {
    service_principal_name = azurerm_user_assigned_identity.app.client_id
    permission_level       = "CAN_RESTART"
  }

  depends_on = [databricks_mws_permission_assignment.app_dev]
}

# Gate 4: what it may read.
#
# databricks_grant - SINGULAR. This is the distinction flagged on Day 4 and this
# is the situation it exists for.
#
# The PLURAL databricks_grants is AUTHORITATIVE: it declares the complete
# privilege set for a securable and revokes anything absent. The unity-catalog
# module already owns `databricks_grants` on the dev catalog. If this module
# declared one too, each apply would erase the other's grants - a permanent
# flip-flop between two modules, both "working", neither converging.
#
# The singular resource manages ONE principal's privileges and leaves the rest
# alone. Use it whenever a securable has more than one owner in the codebase.
#
# Scoped to the gold SCHEMA, not the catalog: the app serves gold and has no
# business reading bronze or silver. Granting at catalog level would silently
# widen its access every time a schema is added.
resource "databricks_grant" "gold_catalog" {
  provider   = databricks.dev
  catalog    = var.catalog
  principal  = azurerm_user_assigned_identity.app.client_id
  privileges = ["USE_CATALOG"] # traversal only - no data access

  depends_on = [databricks_mws_permission_assignment.app_dev]
}

resource "databricks_grant" "gold_schema" {
  provider   = databricks.dev
  schema     = "${var.catalog}.gold"
  principal  = azurerm_user_assigned_identity.app.client_id
  privileges = ["USE_SCHEMA", "SELECT"]

  depends_on = [databricks_grant.gold_catalog]
}
