# --- Grants ---------------------------------------------------------------
#
# SINGULAR `databricks_grant`, one resource per principal. This was
# `databricks_grants` (PLURAL) and the change is a correctness fix, not a
# refactor.
#
# THE DISTINCTION:
#
#   databricks_grants  AUTHORITATIVE. Declares the COMPLETE privilege set for a
#                      securable and revokes anything not listed. Perfect when
#                      exactly one place in the codebase grants on that object.
#
#   databricks_grant   Manages ONE principal's privileges and leaves every other
#                      principal alone. Correct when a securable has more than
#                      one owner in the repo.
#
# This catalog has two owners. data/catalog grants the human groups and the
# pipeline identity; app/deploy grants the storefront and console identities on
# the same catalog. With the authoritative resource, each apply silently revoked
# the other's grants - a permanent flip-flop where both modules report success,
# neither converges, and the serving tier starts reporting that gold tables do
# not exist.
#
# The cost of the singular form is real and worth stating: a privilege granted
# by hand in the UI to a principal NOT listed here will survive, because nothing
# declares the complete set any more. The repo stops being able to prove a
# negative. That is the trade you make for shared ownership, and drift detection
# is what covers it.
#
# INHERITANCE is unchanged either way: privileges cascade down. SELECT at
# catalog level applies to every schema and table beneath, including ones that
# do not exist yet. That is why analysts get traversal at the catalog and their
# SELECT at the schema: a catalog-level SELECT would silently hand them every
# layer added from now on, including bronze.


resource "databricks_grant" "catalog" {
  for_each = var.catalog_grants

  catalog    = databricks_catalog.this.name
  principal  = each.key
  privileges = each.value

  # Same reason the schemas wait: an unbound ISOLATED catalog is not visible to
  # the workspace this provider is talking to, so the grant call would 404.
  depends_on = [databricks_workspace_binding.this]
}

# Schema-level grants. The map is schema name -> principal -> privileges, so the
# medallion layers can stop being uniform - which is the point of having them.
#
# Flattened into a single map because Terraform cannot nest for_each. The key
# has to be stable across plans, so it is built from the two names rather than
# from an index.
locals {
  schema_grant_pairs = merge([
    for schema_name, principals in var.schema_grants : {
      for principal, privileges in principals :
      "${schema_name}|${principal}" => {
        schema     = schema_name
        principal  = principal
        privileges = privileges
      }
    }
  ]...)
}

resource "databricks_grant" "schema" {
  for_each = local.schema_grant_pairs

  schema     = "${databricks_catalog.this.name}.${each.value.schema}"
  principal  = each.value.principal
  privileges = each.value.privileges

  depends_on = [databricks_schema.layer]
}

# --- Migrating off the authoritative resource -----------------------------
#
# THE HAZARD, and it is not obvious.
#
# `databricks_grants` and `databricks_grant` are different resource TYPES, so
# Terraform does not see this as a replacement. It sees one resource being
# removed and several being added, with no dependency between them - and it is
# free to order those however it likes.
#
# If the removal runs LAST, its delete revokes the complete privilege set for
# the catalog, including the grants the singular resources just created. The
# apply reports success and every principal loses access to the catalog. Worse,
# the principal running the apply is usually one of them.
#
# A `removed` block with destroy = false makes Terraform FORGET the old resource
# without calling its delete. The privileges stay exactly as they are, the
# singular resources adopt them on the next apply, and nothing is revoked at any
# point. This is the same tool you would reach for when handing a resource to
# another module or another team.
#
# These two blocks are safe to delete once every state file has been applied
# past them. They are kept because a state that has not been applied since the
# change still needs them, and there is more than one of those.

removed {
  from = databricks_grants.catalog

  lifecycle {
    destroy = false
  }
}

removed {
  from = databricks_grants.schema

  lifecycle {
    destroy = false
  }
}
