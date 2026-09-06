# This module does NOT configure a provider. It declares that it needs one and
# the caller passes the right alias in with `providers = { databricks = ... }`.
#
# That is what lets the same module build dev through the dev workspace and prod
# through the prod workspace, with no duplicated resource blocks. A module that
# configured its own provider could not be reused this way - which is why
# provider blocks belong in root modules only.
terraform {
  required_providers {
    databricks = {
      source = "databricks/databricks"
    }
  }
}
