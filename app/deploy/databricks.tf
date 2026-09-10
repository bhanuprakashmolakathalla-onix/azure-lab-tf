# The Databricks half of the serving tier: somewhere to run the query, and two
# identities permitted to run it.

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
# come up; serverless takes seconds, which is the difference between a shop that
# feels broken after idling and one that feels slow for a moment.
#
# ONE warehouse shared by both sites. They query different schemas under
# different identities, which is what the grants below are for - two warehouses
# would double the idle risk to enforce a boundary that is already enforced.
resource "databricks_sql_endpoint" "serving" {
  count = var.serving_compute == "warehouse" ? 1 : 0

  name                      = "wh-serving-2xs"
  cluster_size              = "2X-Small"
  enable_serverless_compute = true

  # The single number that decides whether an occasionally-used pair of sites
  # costs tens of rupees a day or thousands a month. The warehouse bills only
  # while RUNNING.
  #
  # Lower is not automatically better - restarting on every request is its own
  # kind of waste, and a shopper who waits ten seconds twice leaves. Ten minutes
  # covers a browsing session and closes the tail afterwards.
  auto_stop_mins = var.warehouse_auto_stop_mins

  # One cluster. Scaling out serves concurrent users; there are two apps and one
  # person.
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
# A single-node all-purpose cluster serving the same queries. Six-to-eight times
# cheaper per hour and about thirty-five times slower to start.
#
# data_security_mode SINGLE_USER pinned to the SHOP's identity: single-user mode
# gives full Unity Catalog access under exactly one principal, so this option
# cannot serve both sites at once. That is the honest cost of the cheap path and
# the reason "warehouse" is the default.
resource "databricks_cluster" "serving" {
  count = var.serving_compute == "cluster" ? 1 : 0

  cluster_name  = "serving-fashion"
  spark_version = data.databricks_spark_version.lts.id
  node_type_id  = var.node_type_id
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
  single_user_name   = azurerm_user_assigned_identity.app["shop"].client_id
}

data "databricks_spark_version" "lts" {
  long_term_support = true
}

# The HTTP path the connector uses. Warehouses and clusters expose different
# shapes, and this is the ONLY place the choice leaks into anything else.
locals {
  serving_http_path = var.serving_compute == "warehouse" ? (
    databricks_sql_endpoint.serving[0].odbc_params[0].path
    ) : (
    "/sql/protocolv1/o/${local.ws.workspace_id}/${databricks_cluster.serving[0].id}"
  )

  # What each site may touch, declared once and applied below. Reading this
  # block should be enough to answer "can the shop see silver?" without opening
  # anything else.
  #
  # The shop holds CREATE_TABLE on ops because it creates the order book on
  # first checkout - see the note in app/src/db.py about why that DDL is not
  # Terraform. The console deliberately does not: it works the orders, it does
  # not define them.
  schema_grants = {
    "shop|gold"      = { identity = "shop", schema = "gold", privileges = ["USE_SCHEMA", "SELECT"] }
    "shop|ops"       = { identity = "shop", schema = "ops", privileges = ["USE_SCHEMA", "SELECT", "MODIFY", "CREATE_TABLE"] }
    "console|gold"   = { identity = "console", schema = "gold", privileges = ["USE_SCHEMA", "SELECT"] }
    "console|silver" = { identity = "console", schema = "silver", privileges = ["USE_SCHEMA", "SELECT"] }
    "console|ops"    = { identity = "console", schema = "ops", privileges = ["USE_SCHEMA", "SELECT", "MODIFY"] }
  }
}

# --- The apps' identities, Databricks side --------------------------------
#
# A managed identity's CLIENT ID is its application id in Entra, and that is the
# value Databricks registers. One identity, two directories, linked by that
# GUID - the same three-object shape as the CI principal.
#
# NOTE for a future teardown: destroying these DEACTIVATES rather than deletes
# the account record. It does not bite the way it bit CI, because destroying
# this module also destroys the managed identities - so a rebuild produces NEW
# client ids and fresh registrations rather than colliding with the old ones.
# The cost is an inactive record left behind per rebuild.
resource "databricks_service_principal" "app" {
  for_each = azurerm_user_assigned_identity.app
  provider = databricks.account

  application_id = each.value.client_id
  display_name   = "sp-fashion-${each.key}"
}

# Gate 2: may it enter the workspace at all. USER, not ADMIN - these read a
# handful of tables and write one, and need nothing else.
resource "databricks_mws_permission_assignment" "app" {
  for_each = databricks_service_principal.app
  provider = databricks.account

  workspace_id = local.ws.workspace_id
  principal_id = each.value.id
  permissions  = ["USER"]
}

# Gate 3: may it use this warehouse. Separate from data access entirely - a
# principal can hold SELECT on every table and still be unable to run a query,
# because compute permission and data permission are different systems.
resource "databricks_permissions" "warehouse" {
  count           = var.serving_compute == "warehouse" ? 1 : 0
  sql_endpoint_id = databricks_sql_endpoint.serving[0].id

  dynamic "access_control" {
    for_each = azurerm_user_assigned_identity.app
    content {
      service_principal_name = access_control.value.client_id
      permission_level       = "CAN_USE"
    }
  }

  depends_on = [databricks_mws_permission_assignment.app]
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
  count      = var.serving_compute == "cluster" ? 1 : 0
  cluster_id = databricks_cluster.serving[0].id

  dynamic "access_control" {
    for_each = azurerm_user_assigned_identity.app
    content {
      service_principal_name = access_control.value.client_id
      permission_level       = "CAN_RESTART"
    }
  }

  depends_on = [databricks_mws_permission_assignment.app]
}

# Gate 4: what each one may read and write.
#
# databricks_grant - SINGULAR, and now so is the catalog module. The PLURAL
# databricks_grants is AUTHORITATIVE: it declares the complete privilege set for
# a securable and revokes anything absent. While data/catalog used the plural
# form on this catalog, every apply of that module silently stripped the grants
# below and the sites started reporting that gold did not exist. Two modules
# granting on one securable means the singular form in both.
#
# TRAVERSAL AT THE CATALOG, PRIVILEGE AT THE SCHEMA. USE_CATALOG grants no data
# access on its own - it is the right to walk into the catalog. Granting SELECT
# here instead would cascade to every schema that exists and every schema added
# later, which is how a storefront quietly ends up able to read the order book
# of a business unit that did not exist when it was written.
resource "databricks_grant" "catalog" {
  for_each = azurerm_user_assigned_identity.app

  catalog    = var.catalog
  principal  = each.value.client_id
  privileges = ["USE_CATALOG"]

  depends_on = [databricks_mws_permission_assignment.app]
}

resource "databricks_grant" "schema" {
  for_each = local.schema_grants

  schema     = "${var.catalog}.${each.value.schema}"
  principal  = azurerm_user_assigned_identity.app[each.value.identity].client_id
  privileges = each.value.privileges

  depends_on = [databricks_grant.catalog]
}
