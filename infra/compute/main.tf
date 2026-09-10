# Ad-hoc compute. OPTIONAL, and it bills from the moment it applies.
#
# The pipeline in data/pipelines brings its own job cluster and tears it down
# when the run ends. This module exists for the other thing: opening a notebook
# and poking at the lake by hand. Nothing else depends on it, which is why it is
# absent from both CI workflows - a merge to main should never start billing
# DBUs on its own.

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

# Latest long-term-support runtime, rather than a pinned version string that
# quietly goes end-of-support.
data "databricks_spark_version" "lts" {
  long_term_support = true
}

# --- Cluster policy -------------------------------------------------------
#
# A policy is a JSON document of constraints applied at cluster-CREATE time. Two
# things worth internalising:
#
# 1. It constrains what humans can create in the UI, which is where runaway cost
#    actually comes from. Terraform is not the risk; a colleague picking 8
#    workers is.
#
# 2. Note what is DELIBERATELY ABSENT: any constraint on node_type_id. Pinning an
#    allowlist of SKUs in a POLICY is different from pinning one in a resource -
#    the policy would also block the operator from routing around a stockout by
#    hand, which is the one escape hatch worth keeping.
resource "databricks_cluster_policy" "lab" {
  name = "lab-cost-guardrails"

  definition = jsonencode({
    "autotermination_minutes" : {
      "type" : "range",
      "maxValue" : 30,
      "defaultValue" : 20
    },
    "num_workers" : {
      "type" : "range",
      "minValue" : 0,
      "maxValue" : 2
    }
    # NOTE: there is deliberately NO custom_tags rule here, and the reason is
    # Azure-specific.
    #
    # Azure propagates a Databricks workspace's RESOURCE tags down onto every
    # cluster it launches, as DEFAULT tags. The workspace already carries
    # autodelete=true, so every cluster inherits it for free. Pinning
    # custom_tags.autodelete in the policy collides with that inherited tag -
    # Databricks renames one to resolve the conflict, the policy then cannot
    # find the tag it required, and cluster creation fails validation.
    #
    # The guarantee you wanted is already there, enforced one layer up where a
    # user cannot opt out of it.
  })
}

# --- The cluster ----------------------------------------------------------
#
# NODE TYPE IS PINNED, NOT DISCOVERED - same reason as data/pipelines, and this
# module used to get it wrong.
#
# `data "databricks_node_type"` with min_cores = 4 asks DATABRICKS for the
# smallest matching node. Databricks knows the Azure catalogue; it has no
# visibility into your subscription's quota or your region's capacity, so it
# returns a SKU you may not be permitted to allocate. Here it resolved to
# Standard_D4ds_v6, which cannot launch on this subscription, and the failure
# arrives minutes later at cluster start rather than at apply.
#
# A SKU must clear THREE gates: Azure capacity (az vm list-skus), Azure quota
# (az vm list-usage), and the Databricks supported-node list.
#
# NOTE: applying this STARTS the cluster and starts billing - VM plus DBUs, very
# roughly Rs 45/hour. autotermination_minutes is what stops that becoming an
# overnight mistake.
resource "databricks_cluster" "single" {
  cluster_name  = "lab01-single"
  spark_version = data.databricks_spark_version.lts.id
  node_type_id  = var.node_type_id
  policy_id     = databricks_cluster_policy.lab.id

  autotermination_minutes = var.autotermination_minutes

  # Single-node is not a first-class flag - it is this trio. num_workers = 0
  # plus a local master plus the ResourceClass tag is how Databricks recognises
  # the shape. Miss one and you get a driver waiting forever for workers.
  num_workers = 0

  spark_conf = {
    "spark.databricks.cluster.profile" = "singleNode"
    "spark.master"                     = "local[*]"
  }

  # ResourceClass only. autodelete arrives automatically as a default tag,
  # inherited from the workspace's Azure tags - setting it again here is what
  # triggered the naming conflict.
  custom_tags = {
    "ResourceClass" = "SingleNode"
  }

  # Required for Unity Catalog. SINGLE_USER is the mode that supports the full
  # Spark API against UC tables; the shared mode trades some of that away for
  # multi-user isolation you do not need in a one-person lab.
  data_security_mode = "SINGLE_USER"
  single_user_name   = var.single_user_name
}
