locals {
  # File names, not layer names. 00_generate_source is not a medallion layer -
  # it fakes the upstream systems (POS, WMS, returns) dropping files into the
  # landing zone so Auto Loader has something to discover. On a real platform
  # that notebook does not exist; files arrive from elsewhere.
  notebooks = [
    "00_generate_source",
    "01_bronze",
    "02_silver",
    "03_gold",
  ]
}

# Create the parent folder explicitly.
#
# databricks_notebook will create missing parent folders implicitly, but the
# notebooks are created in PARALLEL - so all four check for the folder at once,
# one wins, and the losers fail with "parent folder does not exist". It worked
# in an earlier run only by luck of timing.
#
# The general shape: whenever a provider creates something implicitly as a side
# effect, concurrent resources depending on that side effect will race. Make the
# shared thing explicit and depend on it.
resource "databricks_directory" "root" {
  path = var.notebook_root
}

resource "databricks_notebook" "layer" {
  for_each = toset(local.notebooks)

  path     = "${var.notebook_root}/${each.value}"
  language = "PYTHON"
  source   = "${path.module}/notebooks/${each.value}.py"
  md5      = filemd5("${path.module}/notebooks/${each.value}.py")

  depends_on = [databricks_directory.root]
}

# NODE TYPE IS PINNED, NOT DISCOVERED - and that is deliberate.
#
# The obvious code here is a databricks_node_type data source asking for the
# smallest 4-core general-purpose node. It was, and it returned Standard_D4ds_v6,
# which CANNOT LAUNCH on this subscription.
#
# The data source asks DATABRICKS what the smallest matching node is. Databricks
# knows the Azure catalogue. It has no visibility into your subscription quota or
# your regions capacity, so it confidently returns a SKU you are not permitted to
# allocate and the failure lands five minutes later at cluster launch.
#
# Both gates have to be checked by hand, against your own subscription:
#   az vm list-skus  --location <r> --query "[?restrictions[0]==null].name"
#   az vm list-usage --location <r>
#
# THIRD GATE: Databricks keeps its own supported-node-type list, and the
# premium-storage "b" families (E4bds_v5) are NOT on it - the job API rejects
# them outright. So a SKU must clear capacity AND quota AND Databricks support.
#
# In CentralIndia here the three-way intersection was initially EMPTY: every
# SKU with capacity + Databricks support sat in DSv5/DDSv5/ESv5/EDSv5, all at
# quota 0. Fixed by requesting 8 vCPUs of DDSv5, which was auto-approved and
# also raised Total Regional from 10 to 18.
#
# D4ds_v5: 4 vCPU, 16 GiB, local NVMe temp disk (the trailing d), which Spark
# wants for shuffle.
#
# BUDGET: Total Regional vCPUs = 10. Jumpbox holds 4, this holds 4. There is no
# room for a second worker, which is why num_workers = 0 is a constraint here
# rather than a preference.

data "databricks_spark_version" "lts" {
  long_term_support = true
}

resource "databricks_job" "fashion" {
  name        = "fashion-medallion"
  description = "Generated drops -> ${var.catalog}.bronze -> silver -> gold"

  # One job cluster shared by all four tasks. Measured on an earlier run: 351s
  # of cold start paid ONCE, then ~1s of setup per subsequent task. Give each
  # task its own cluster and the same work costs 4x351s of boot time before any
  # of it computes anything.
  job_cluster {
    job_cluster_key = "pipeline"

    new_cluster {
      spark_version = data.databricks_spark_version.lts.id
      node_type_id  = var.node_type_id
      num_workers   = 0

      spark_conf = {
        "spark.databricks.cluster.profile" = "singleNode"
        "spark.master"                     = "local[*]"
      }

      custom_tags = {
        "ResourceClass" = "SingleNode"
      }

      # SINGLE_USER is not a convenience setting here - it is required. Unity
      # Catalog streaming writes (Auto Loader -> toTable) are unsupported on
      # shared access mode, and the failure surfaces as an opaque permissions
      # error rather than a capability one.
      data_security_mode = "SINGLE_USER"
      single_user_name   = var.ci_application_id
    }
  }

  # ORDER MATTERS HERE, AND NOT FOR THE REASON IT LOOKS LIKE.
  #
  # These blocks are listed bronze -> gold -> seed -> silver, which reads wrong.
  # Execution order is NOT set by block order - it comes from the depends_on
  # blocks, and is still seed -> bronze -> silver -> gold.
  #
  # The listing is alphabetical because that is how the Databricks API returns
  # tasks when Terraform reads the job back. `task` is a LIST, matched
  # positionally, so a config ordered seed/bronze/silver/gold against an API
  # response ordered bronze/gold/seed/silver produces a diff on every plan - one
  # that applies successfully and reappears immediately.
  #
  # A perpetual diff is worse than it sounds in CI: no run is ever clean, so
  # "no changes" stops carrying information and people stop reading plans.
  task {
    task_key        = "bronze"
    job_cluster_key = "pipeline"

    depends_on {
      task_key = "seed"
    }

    notebook_task {
      notebook_path = databricks_notebook.layer["01_bronze"].path
      base_parameters = {
        catalog         = var.catalog
        landing_url     = var.landing_url
        checkpoints_url = var.checkpoints_url
      }
    }
  }

  task {
    task_key        = "gold"
    job_cluster_key = "pipeline"

    depends_on {
      task_key = "silver"
    }

    notebook_task {
      notebook_path   = databricks_notebook.layer["03_gold"].path
      base_parameters = { catalog = var.catalog }
    }
  }

  task {
    task_key        = "seed"
    job_cluster_key = "pipeline"

    notebook_task {
      notebook_path = databricks_notebook.layer["00_generate_source"].path
      base_parameters = {
        catalog     = var.catalog
        landing_url = var.landing_url
        start_date  = var.start_date
        num_days    = var.num_days
        seed        = "42"
      }
    }
  }

  task {
    task_key        = "silver"
    job_cluster_key = "pipeline"

    depends_on {
      task_key = "bronze"
    }

    notebook_task {
      notebook_path   = databricks_notebook.layer["02_silver"].path
      base_parameters = { catalog = var.catalog }
    }
  }

  # The job runs as the SERVICE PRINCIPAL, not as you. That is what makes the
  # pipeline reproducible when you are on leave, and it is why the delegation
  # rule set in data/catalog exists - workspace admin alone does not grant the
  # right to bind another principal to run_as.
  run_as {
    service_principal_name = var.ci_application_id
  }

  email_notifications {
    no_alert_for_skipped_runs = true
  }
}
