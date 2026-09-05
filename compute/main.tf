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

# --- Let Databricks choose the node type ----------------------------------
#
# THE Day 1 lesson, encoded.
#
# Central India had capacity stockouts (CLOUD_PROVIDER_RESOURCE_STOCKOUT) on
# Standard_D4s_v3 and Standard_DS3_v2. Quota is NOT capacity: your quota said 10
# vCPUs were yours, and Azure still had no machines to give.
#
# Hardcoding a SKU here - or worse, allowlisting one in the cluster policy -
# converts a transient regional shortage into a hard blocker, because it removes
# Databricks' ability to fall back to a different family. Asking for a SHAPE and
# letting Databricks resolve it is what keeps you running.
data "databricks_node_type" "smallest" {
  local_disk    = true
  min_cores     = 4
  min_memory_gb = 8
  category      = "General Purpose"
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
#    allowlist of SKUs is the single most common way people turn a stockout into
#    an outage. Constrain the SIZE of the bill, not the shape of the machine.
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
# Single node: driver only, no workers. 4 vCPUs against a 10 vCPU regional quota,
# which leaves headroom and is plenty for reading samples.nyctaxi.
#
# NOTE: applying this STARTS the cluster and starts billing. VM plus DBUs is
# roughly Rs 20/hour. autotermination_minutes is what stops that becoming a
# Rs 500 mistake overnight.
resource "databricks_cluster" "single" {
  cluster_name  = "lab01-single"
  spark_version = data.databricks_spark_version.lts.id
  node_type_id  = data.databricks_node_type.smallest.id
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
