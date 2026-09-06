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

locals {
  foundation = data.terraform_remote_state.foundation.outputs
  workspaces = data.terraform_remote_state.workspace.outputs
}

# --- Metastore-level objects ---------------------------------------------
#
# The storage credential and external locations are METASTORE-scoped, not
# workspace-scoped. They only need to be created once, through any workspace -
# we use dev. Their own isolation_mode is left at the default (OPEN) so that both
# catalogs can build on them.
#
# Tightening these too is a real option on a production platform: an external
# location can be isolated and bound just like a catalog. Left open here so the
# experiment isolates ONE variable - the catalog.
resource "databricks_storage_credential" "adls" {
  provider = databricks.dev

  name    = "sc-lab01-adls"
  comment = "Managed identity for the lab lake. Managed by Terraform."

  azure_managed_identity {
    access_connector_id = local.foundation.access_connector_id
  }

  force_destroy = true
}

resource "databricks_external_location" "layers" {
  provider = databricks.dev
  for_each = local.foundation.container_urls

  name            = "el-lab01-${each.key}"
  url             = each.value
  credential_name = databricks_storage_credential.adls.name
  comment         = "Lab lake: ${each.key}"

  force_destroy = true
}

# --- One catalog per environment, each through ITS OWN provider -----------
#
# Same module, twice, with a different provider alias passed in each time. This
# is the pattern that makes isolation manageable: dev's objects are created
# through the dev workspace, prod's through prod, because an ISOLATED catalog is
# invisible from anywhere it is not bound.
#
# Terraform cannot select a provider dynamically from a for_each key, which is
# exactly why this is two module calls rather than one keyed resource. That
# limitation is not a wart - it is what forces the provider choice to be explicit
# and reviewable in the diff.
module "catalog_dev" {
  source = "./modules/catalog"

  providers = {
    databricks = databricks.dev
  }

  name         = "dev"
  storage_root = local.foundation.container_urls["managed-dev"]
  workspace_id = local.workspaces.workspace_ids["dev"]
  schemas      = var.schemas

  # dev is where work happens: engineers can create and modify, analysts read.
  #
  # USE_CATALOG is the one everybody forgets. It grants NO data access on its own
  # - it is the right to traverse into the catalog at all. Without it, SELECT on
  # a table beneath is unreachable and the error says the table does not exist.
  # Three levels, three traversal grants: USE_CATALOG, USE_SCHEMA, then SELECT.
  catalog_grants = {
    (databricks_group.engineers.display_name) = ["USE_CATALOG", "USE_SCHEMA", "CREATE_SCHEMA", "CREATE_TABLE", "SELECT", "MODIFY"]
    (databricks_group.analysts.display_name)  = ["USE_CATALOG", "USE_SCHEMA", "SELECT"]

    # The pipeline identity needs dev too, not just prod. Easy to miss precisely
    # because prod is the one that feels like it needs guarding - but a job that
    # cannot write to dev is a job you cannot test before promoting it.
    (databricks_service_principal.ci.application_id) = ["USE_CATALOG", "USE_SCHEMA", "CREATE_SCHEMA", "CREATE_TABLE", "MODIFY", "SELECT"]
  }

  depends_on = [databricks_external_location.layers]
}

module "catalog_prod" {
  source = "./modules/catalog"

  providers = {
    databricks = databricks.prod
  }

  name         = "prod"
  storage_root = local.foundation.container_urls["managed-prod"]
  workspace_id = local.workspaces.workspace_ids["prod"]
  schemas      = var.schemas

  # prod is read-only for humans. Nobody gets MODIFY or CREATE_TABLE - production
  # data arrives through jobs running as a service principal, never through a
  # person at a keyboard.
  #
  # Note this is the SECOND, independent layer. The READ_ONLY binding below
  # already makes writes from the dev workspace impossible for everyone; this
  # makes writes impossible for these groups from ANY workspace. Belt and braces,
  # and they fail differently - the binding says "no such catalog", the grant
  # says "permission denied".
  catalog_grants = {
    (databricks_group.engineers.display_name) = ["USE_CATALOG", "USE_SCHEMA", "SELECT"]
    (databricks_group.analysts.display_name)  = ["USE_CATALOG", "USE_SCHEMA", "SELECT"]

    # The only principal that can WRITE to production, and it is not a person.
    # Note it is keyed by APPLICATION ID - UC identifies service principals that
    # way, not by display name the way it does groups.
    (databricks_service_principal.ci.application_id) = ["USE_CATALOG", "USE_SCHEMA", "CREATE_SCHEMA", "CREATE_TABLE", "MODIFY", "SELECT"]
  }

  # dev may read prod, never write to it. Note the asymmetry: catalog_dev grants
  # prod no reciprocal access, so production cannot depend on dev data by accident.
  read_only_workspace_ids = {
    dev = local.workspaces.workspace_ids["dev"]
  }

  depends_on = [databricks_external_location.layers]
}

# --- Account-level identity ----------------------------------------------
#
# Two groups, deliberately named for ROLES rather than people or teams. Grants
# attach to groups and membership changes without touching the grant graph -
# which is the only way this stays maintainable past about five people.
resource "databricks_group" "engineers" {
  provider     = databricks.account
  display_name = "data-engineers"
}

resource "databricks_group" "analysts" {
  provider     = databricks.account
  display_name = "data-analysts"
}

# Find yourself at account level so you can be put in a group.
data "databricks_user" "me" {
  provider  = databricks.account
  user_name = var.owner_user_name
}

resource "databricks_group_member" "me_engineer" {
  provider  = databricks.account
  group_id  = databricks_group.engineers.id
  member_id = data.databricks_user.me.id
}

# --- Workspace assignment -------------------------------------------------
#
# The step that is easy to miss, because everything looks correct without it.
#
# An account-level group with catalog grants still cannot LOG IN to a workspace.
# Identity, assignment and authorization are three independent systems:
#
#   databricks_group                -> the principal exists in the account
#   databricks_mws_permission_...   -> it may enter this workspace   <- THIS
#   databricks_grants               -> what it may touch once inside
#
# Miss the middle one and grants are inert: perfectly correct privileges on a
# catalog the user can never reach. The symptom is a user who "has access" per
# the catalog UI but cannot open the workspace.
#
# GCP has no real equivalent - an IAM binding on a BigQuery dataset is sufficient
# on its own. Databricks separates them because a workspace is a tenancy boundary,
# not just a permissions scope.
resource "databricks_mws_permission_assignment" "engineers_dev" {
  provider     = databricks.account
  workspace_id = local.workspaces.workspace_ids["dev"]
  principal_id = databricks_group.engineers.id
  permissions  = ["USER"]
}

resource "databricks_mws_permission_assignment" "analysts_dev" {
  provider     = databricks.account
  workspace_id = local.workspaces.workspace_ids["dev"]
  principal_id = databricks_group.analysts.id
  permissions  = ["USER"]
}

# Engineers get prod too - but note what that does NOT give them. The prod
# catalog grants withhold MODIFY and CREATE_TABLE, and the READ_ONLY binding
# blocks writes from the dev workspace entirely. Workspace access is the right to
# walk in the door, nothing more.
resource "databricks_mws_permission_assignment" "engineers_prod" {
  provider     = databricks.account
  workspace_id = local.workspaces.workspace_ids["prod"]
  principal_id = databricks_group.engineers.id
  permissions  = ["USER"]
}

# Analysts are deliberately NOT assigned to prod. Three layers of "no", each
# failing differently and each independently sufficient.

# --- CI service principal -------------------------------------------------
#
# This creates a SECOND identity. The Entra service principal already exists;
# this is its Databricks counterpart, and the two are linked only by
# application_id. Three objects now represent one robot:
#
#   Entra application      399c031a-...  the global definition
#   Entra service principal cecdbc56-... holds AZURE role assignments
#   Databricks SP          (its own id)  holds DATABRICKS permissions and grants
#
# Mixing up which id a given API wants is the main friction here. UC GRANTS
# reference a service principal by its APPLICATION ID, while workspace
# assignment wants the Databricks SP's numeric id.
resource "databricks_service_principal" "ci" {
  provider       = databricks.account
  application_id = var.ci_application_id
  display_name   = "sp-terraform-lab"
}

# ADMIN, not USER. This identity has to manage clusters, jobs and permissions
# inside both workspaces, which USER cannot do.
#
# Worth noticing the asymmetry with humans: no PERSON is a workspace admin in
# prod, but the robot is. That is the point - production changes go through a
# reviewed pipeline running as this principal, not through someone's console.
resource "databricks_mws_permission_assignment" "ci_dev" {
  provider     = databricks.account
  workspace_id = local.workspaces.workspace_ids["dev"]
  principal_id = databricks_service_principal.ci.id
  permissions  = ["ADMIN"]
}

resource "databricks_mws_permission_assignment" "ci_prod" {
  provider     = databricks.account
  workspace_id = local.workspaces.workspace_ids["prod"]
  principal_id = databricks_service_principal.ci.id
  permissions  = ["ADMIN"]
}

# --- Delegation: who may RUN AS the service principal ---------------------
#
# Holding workspace admin does NOT let you make a job run as some other
# principal. If it did, anyone with admin could borrow the one identity that can
# write to prod, and every boundary built on Days 4 and 5 would be decorative.
#
# Databricks models this as a role ON the service principal itself:
#
#   roles/servicePrincipal.user     - may run things AS it (bind it to run_as)
#   roles/servicePrincipal.manager  - may change the principal and its delegation
#
# The rule set is AUTHORITATIVE for this one principal, exactly like
# databricks_grants is for a catalog. Note the scope though - it names a single
# servicePrincipals/<app id> path, so a mistake here cannot affect account
# administration. The equivalent rule set at accounts/<id>/ruleSets/default IS
# the account admin list, and that one deserves real caution.
resource "databricks_access_control_rule_set" "ci_delegation" {
  provider = databricks.account
  name     = "accounts/${var.databricks_account_id}/servicePrincipals/${var.ci_application_id}/ruleSets/default"

  # You: full control, including handing this delegation to others.
  grant_rules {
    role       = "roles/servicePrincipal.manager"
    principals = [data.databricks_user.me.acl_principal_id]
  }

  # Engineers may DEPLOY jobs that run as the pipeline identity, but cannot
  # modify the principal itself or widen its access. That split is the point:
  # the ability to use an identity is separate from the ability to change it.
  grant_rules {
    role = "roles/servicePrincipal.user"
    principals = [
      data.databricks_user.me.acl_principal_id,
      databricks_group.engineers.acl_principal_id,
    ]
  }
}

# --- Account admin --------------------------------------------------------
#
# Account admin is a SCIM ROLE on the principal, not an entry in a rule set.
# Rule sets govern access TO a resource (this service principal, this group);
# account_admin is an attribute OF an identity. Different model, different
# resource - `roles/account_admin` in a rule set is rejected as unsupported.
#
# The distinction matters beyond the syntax error, because this resource is
# ADDITIVE and per-principal. There is no authoritative list to accidentally
# omit yourself from, so the lockout risk that applies to
# databricks_access_control_rule_set simply does not exist here.
#
# Why CI needs it: without account admin the service principal cannot manage
# groups, workspace assignments, or delegation - so this module could never run
# in CI, leaving the one that governs who can access what as the only module
# with no review gate.
resource "databricks_service_principal_role" "ci_account_admin" {
  provider             = databricks.account
  service_principal_id = databricks_service_principal.ci.id
  role                 = "account_admin"
}
