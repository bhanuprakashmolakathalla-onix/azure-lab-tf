# Unity Catalog for the fashion platform: one catalog, three layers, grants that
# mean something.
#
# CHANGED FROM THE DEV/PROD BUILD. There is one workspace now, so the two-catalog
# isolation experiment is gone. What is NOT gone is isolation_mode = ISOLATED on
# the catalog: a metastore is REGION-WIDE, so any workspace attached to it later
# sees every OPEN catalog by default. ISOLATED means deny-by-default, and the
# binding below is the single explicit exception. Worth keeping even with one
# workspace, because the failure it prevents is somebody else's future workspace,
# not yours.

data "terraform_remote_state" "foundation" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "foundation.tfstate"
    use_azuread_auth     = true
  }
}

data "terraform_remote_state" "workspace" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "workspace.tfstate"
    use_azuread_auth     = true
  }
}

data "terraform_remote_state" "governance" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "governance.tfstate"
    use_azuread_auth     = true
  }
}

locals {
  foundation   = data.terraform_remote_state.foundation.outputs
  workspace_id = data.terraform_remote_state.workspace.outputs.workspace_id

  # Numeric Databricks id of the CI principal, owned by governance so it survives
  # a teardown of this module.
  ci_sp_id = data.terraform_remote_state.governance.outputs.ci_sp_id
}

# --- Account-level identity ----------------------------------------------
#
# Groups named for ROLES, not people. Grants attach to groups, membership moves
# underneath, and the grant graph stops needing edits every time someone joins.

resource "databricks_group" "engineers" {
  provider     = databricks.account
  display_name = "data-engineers"
}

resource "databricks_group" "analysts" {
  provider     = databricks.account
  display_name = "data-analysts"
}

# --- Ownership group ------------------------------------------------------
#
# Whoever creates a UC object owns it, so without this everything is owned by
# Bhanu personally. That breaks twice: CI cannot manage what it does not own
# (account admin governs the ACCOUNT and grants nothing inside the metastore),
# and a person leaving makes their objects unmanageable.
resource "databricks_group" "platform_admins" {
  provider     = databricks.account
  display_name = "platform-admins"
}

data "databricks_user" "me" {
  provider  = databricks.account
  user_name = var.owner_user_name
}

resource "databricks_group_member" "platform_admin_me" {
  provider  = databricks.account
  group_id  = databricks_group.platform_admins.id
  member_id = data.databricks_user.me.id
}

resource "databricks_group_member" "platform_admin_ci" {
  provider  = databricks.account
  group_id  = databricks_group.platform_admins.id
  member_id = local.ci_sp_id
}

resource "databricks_group_member" "me_engineer" {
  provider  = databricks.account
  group_id  = databricks_group.engineers.id
  member_id = data.databricks_user.me.id
}

# --- Workspace assignment -------------------------------------------------
#
# The step that is easy to miss because everything looks correct without it.
# Three independent systems, and all three are required:
#
#   databricks_group              -> the principal exists in the account
#   databricks_mws_permission_... -> it may ENTER this workspace     <- THIS
#   databricks_grants             -> what it may touch once inside
#
# Miss the middle one and grants are inert: correct privileges on a catalog the
# principal can never reach. Worse, ownership handed to an UNASSIGNED group locks
# everyone out, which is exactly how Day 8 broke - the transfer succeeded and
# every principal instantly lost access, because nobody's workspace identity
# carried platform-admins.
#
# GCP has no equivalent. An IAM binding on a BigQuery dataset is sufficient on
# its own; there is no "may this principal enter the project" step. Databricks
# splits them because a workspace is a TENANCY boundary, not just a permission
# scope.
resource "databricks_mws_permission_assignment" "platform_admins" {
  provider     = databricks.account
  workspace_id = local.workspace_id
  principal_id = databricks_group.platform_admins.id
  permissions  = ["ADMIN"]
}

resource "databricks_mws_permission_assignment" "engineers" {
  provider     = databricks.account
  workspace_id = local.workspace_id
  principal_id = databricks_group.engineers.id
  permissions  = ["USER"]
}

resource "databricks_mws_permission_assignment" "analysts" {
  provider     = databricks.account
  workspace_id = local.workspace_id
  principal_id = databricks_group.analysts.id
  permissions  = ["USER"]
}

# ADMIN, not USER: CI manages clusters, jobs and permissions inside the
# workspace, which USER cannot do. Note the asymmetry with humans - platform
# changes go through a reviewed pipeline running as this principal, not through
# someone's console.
resource "databricks_mws_permission_assignment" "ci" {
  provider     = databricks.account
  workspace_id = local.workspace_id
  principal_id = local.ci_sp_id
  permissions  = ["ADMIN"]
}

# --- Metastore-scoped storage --------------------------------------------
#
# The storage credential and external locations are METASTORE-scoped, not
# workspace-scoped - created once, through any workspace.
#
# THE PRIVATE-NETWORKING CATCH: creating a storage credential triggers a
# validation that runs from the Databricks CONTROL PLANE, outside your VNet. It
# reaches the lake over the public endpoint, which the foundation firewall denies
# to everything except the Access Connector named in private_link_access. That
# exception is the only reason this resource can be created at all against a
# closed storage account, and it is why foundation uses network_rules with
# default_action = Deny rather than public_network_access_enabled = false.
resource "databricks_storage_credential" "adls" {
  name    = "sc-lab01-adls"
  comment = "Managed identity for the fashion lake. Managed by Terraform."

  # Group, never a person.
  owner = databricks_group.platform_admins.display_name

  azure_managed_identity {
    access_connector_id = local.foundation.access_connector_id
  }

  force_destroy = true

  # NOT redundant. Terraform implicit dependencies follow REFERENCES, and `owner`
  # references the group display_name - not its membership, and not its workspace
  # assignment. Without this, Terraform may legally hand ownership to
  # platform-admins BEFORE anyone is in it or it can enter the workspace, and the
  # apply loses its own permissions half way through.
  #
  # On DESTROY Terraform walks this graph backwards, so listing the assignment
  # here is also what guarantees it is torn down AFTER the objects that depend on
  # it. Destroy ordering is the half of a dependency graph nobody tests until the
  # day they need it.
  depends_on = [
    databricks_group_member.platform_admin_me,
    databricks_group_member.platform_admin_ci,
    databricks_mws_permission_assignment.platform_admins,
  ]
}

resource "databricks_external_location" "layers" {
  for_each = local.foundation.container_urls

  name            = "el-lab01-${each.key}"
  url             = each.value
  credential_name = databricks_storage_credential.adls.name
  comment         = "Fashion lake: ${each.key}"
  owner           = databricks_group.platform_admins.display_name

  force_destroy = true
}

# --- The catalog ----------------------------------------------------------

module "catalog" {
  source = "./modules/catalog"

  providers = {
    databricks = databricks
  }

  name         = var.catalog_name
  storage_root = local.foundation.container_urls["managed"]
  workspace_id = local.workspace_id
  schemas      = var.schemas
  owner        = databricks_group.platform_admins.display_name

  # USE_CATALOG is the one everybody forgets. It grants NO data access on its own
  # - it is the right to TRAVERSE into the catalog. Without it, SELECT on a table
  # beneath is unreachable and the error claims the table does not exist. Three
  # levels, three traversal grants: USE_CATALOG, USE_SCHEMA, then SELECT.
  #
  # Grants also INHERIT downward: SELECT here applies to every schema and table
  # in the catalog, including ones that do not exist yet. That makes catalog-level
  # SELECT a bigger decision than it looks.
  catalog_grants = {
    (databricks_group.engineers.display_name) = ["USE_CATALOG", "USE_SCHEMA", "CREATE_SCHEMA", "CREATE_TABLE", "SELECT", "MODIFY"]

    # Analysts read, and only read. No MODIFY, no CREATE_TABLE.
    (databricks_group.analysts.display_name) = ["USE_CATALOG", "USE_SCHEMA", "SELECT"]

    # The pipeline identity. Keyed by APPLICATION ID - UC identifies service
    # principals that way, not by display name the way it does groups.
    (var.ci_application_id) = ["USE_CATALOG", "USE_SCHEMA", "CREATE_SCHEMA", "CREATE_TABLE", "MODIFY", "SELECT"]
  }

  depends_on = [databricks_external_location.layers]
}

# --- Delegation: who may RUN AS the service principal ---------------------
#
# Holding workspace admin does NOT let you make a job run as another principal.
# If it did, anyone with admin could borrow the one identity that writes to the
# lake, and every boundary above would be decorative.
#
# Databricks models this as a role ON the service principal itself:
#   roles/servicePrincipal.user     - may bind it to run_as
#   roles/servicePrincipal.manager  - may change the principal and its delegation
#
# AUTHORITATIVE for this one principal, exactly like databricks_grants is for a
# catalog. Note the scope names a single servicePrincipals/<app id> path, so a
# mistake here cannot affect account administration. The rule set at
# accounts/<id>/ruleSets/default IS the account admin list, and deserves real
# caution.
resource "databricks_access_control_rule_set" "ci_delegation" {
  provider = databricks.account
  name     = "accounts/${var.databricks_account_id}/servicePrincipals/${var.ci_application_id}/ruleSets/default"

  grant_rules {
    role       = "roles/servicePrincipal.manager"
    principals = [data.databricks_user.me.acl_principal_id]
  }

  # Engineers may DEPLOY jobs that run as the pipeline identity, but cannot
  # modify the principal or widen its access. Using an identity and changing it
  # are separate rights.
  grant_rules {
    role = "roles/servicePrincipal.user"
    principals = [
      data.databricks_user.me.acl_principal_id,
      databricks_group.engineers.acl_principal_id,
    ]
  }
}
