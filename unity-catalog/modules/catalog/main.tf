resource "databricks_catalog" "this" {
  name         = var.name
  storage_root = var.storage_root
  comment      = "${var.name} environment. Managed by Terraform."
  owner        = var.owner

  # The line that does the work.
  #
  # OPEN (the default, and what Day 2 built) means every workspace attached to
  # the metastore can see this catalog. Since a metastore is REGION-WIDE and
  # shared, that quietly makes prod readable from dev.
  #
  # ISOLATED inverts it: visible from nothing until explicitly bound below.
  # Deny-by-default, which is the only posture that survives someone adding a
  # workspace later without reading the docs.
  isolation_mode = "ISOLATED"

  force_destroy = true
}

# The binding is what makes an ISOLATED catalog reachable again, from exactly one
# workspace. Note it takes the NUMERIC workspace id.
#
# BINDING_TYPE_READ_WRITE is full access. The alternative, BINDING_TYPE_READ_ONLY,
# is the interesting one for real platforms: it is how you let a dev workspace
# READ prod data without any possibility of writing to it - enforced by the
# metastore, not by a grant someone can change.
resource "databricks_workspace_binding" "this" {
  securable_name = databricks_catalog.this.name
  securable_type = "catalog"
  workspace_id   = var.workspace_id
  binding_type   = "BINDING_TYPE_READ_WRITE"
}

# Schemas MUST come after the binding. Until the catalog is bound, the workspace
# this provider points at cannot see it, and creation fails with a "catalog does
# not exist" that looks nothing like the permissions problem it actually is.
resource "databricks_schema" "layer" {
  for_each = toset(var.schemas)

  catalog_name = databricks_catalog.this.name
  name         = each.value
  comment      = "${each.value} layer"
  owner        = var.owner

  force_destroy = true

  depends_on = [databricks_workspace_binding.this]
}

# --- Read-only bindings ---------------------------------------------------
#
# The pattern real platforms run: let a dev workspace READ production data for
# debugging and schema comparison, with writes structurally impossible.
#
# The distinction worth holding onto is that this is NOT a grant. A grant answers
# "is this principal allowed to write?" and can be changed by anyone with MANAGE.
# A READ_ONLY binding answers "can writes reach this catalog from that workspace
# AT ALL?" - and the answer is no, for every principal, including the catalog
# owner and a metastore admin. Enforced by the metastore before privileges are
# ever consulted.
#
# So the mental model is two independent gates: the BINDING decides whether the
# catalog is reachable and in which direction, and only then do GRANTS decide who
# may do what. Most people conflate them and end up relying on grants alone.
resource "databricks_workspace_binding" "read_only" {
  for_each = var.read_only_workspace_ids

  securable_name = databricks_catalog.this.name
  securable_type = "catalog"
  workspace_id   = each.value
  binding_type   = "BINDING_TYPE_READ_ONLY"

  depends_on = [databricks_workspace_binding.this]
}

# --- Grants ---------------------------------------------------------------
#
# THE thing to know about databricks_grants: it is AUTHORITATIVE. It does not add
# privileges, it declares the complete set for that securable and removes
# anything not listed. Someone runs a GRANT in the UI, the next apply silently
# revokes it.
#
# That is usually what you want on a platform - the repo is the source of truth -
# but it surprises people badly the first time. The non-authoritative sibling is
# `databricks_grant` (singular), which manages one principal's privileges and
# leaves the rest alone. Use it when several teams own slices of one catalog.
#
# INHERITANCE: privileges cascade down. SELECT granted here applies to every
# schema and table in the catalog, including ones that do not exist yet. That is
# why catalog-level SELECT is a bigger decision than it looks.
resource "databricks_grants" "catalog" {
  count = length(var.catalog_grants) > 0 ? 1 : 0

  catalog = databricks_catalog.this.name

  dynamic "grant" {
    for_each = var.catalog_grants
    content {
      principal  = grant.key
      privileges = grant.value
    }
  }

  # Same reason the schemas wait: an unbound ISOLATED catalog is not visible to
  # the workspace this provider is talking to, so the grant call would 404.
  depends_on = [databricks_workspace_binding.this]
}

# Schema-level grants, applied uniformly to every layer.
#
# In a real platform this is where the medallion layers stop being uniform -
# bronze is usually engineers-only, gold is where analysts get SELECT. Kept
# identical here so the mechanism is visible without the policy noise.
resource "databricks_grants" "schema" {
  for_each = length(var.schema_grants) > 0 ? databricks_schema.layer : {}

  schema = "${databricks_catalog.this.name}.${each.value.name}"

  dynamic "grant" {
    for_each = var.schema_grants
    content {
      principal  = grant.key
      privileges = grant.value
    }
  }
}
