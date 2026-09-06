locals {
  # seed_landing is not a medallion layer - it fakes an upstream system dropping
  # files into the landing zone, so Auto Loader has something to discover. On a
  # real platform this task does not exist; files arrive from elsewhere.
  layers = ["seed_landing", "bronze", "silver", "gold"]
}

# Create the parent folder explicitly.
#
# databricks_notebook will create missing parent folders implicitly, but the
# three notebooks are created in PARALLEL - so all three check for the folder at
# once, one wins, and the losers fail with "parent folder does not exist". It
# worked in dev only by luck of timing.
#
# The general shape: whenever a provider creates something implicitly as a side
# effect, concurrent resources depending on that side effect will race. Make the
# shared thing explicit and depend on it.
resource "databricks_directory" "root" {
  path = var.notebook_root
}

resource "databricks_notebook" "layer" {
  for_each = toset(local.layers)

  path     = "${var.notebook_root}/${each.value}"
  language = "PYTHON"
  source   = "${path.module}/notebooks/${each.value}.py"
  md5      = filemd5("${path.module}/notebooks/${each.value}.py")

  depends_on = [databricks_directory.root]
}

# Resolved per environment. Both workspaces sit in the same region so they will
# almost certainly agree, but reading it per module keeps the module honest -
# nothing here assumes another environment's answer.
data "databricks_node_type" "smallest" {
  local_disk    = true
  min_cores     = 4
  min_memory_gb = 8
  category      = "General Purpose"
}

data "databricks_spark_version" "lts" {
  long_term_support = true
}

resource "databricks_job" "medallion" {
  name        = "medallion-${var.env}"
  description = "samples.nyctaxi -> ${var.env}.bronze -> silver -> gold"

  # One job cluster shared by all three tasks. Measured on the dev run: 351s of
  # cold start paid ONCE, then 1s of setup for each subsequent task. Give each
  # task its own cluster and the same work costs 3x351s of boot time.
  job_cluster {
    job_cluster_key = "pipeline"

    new_cluster {
      spark_version = data.databricks_spark_version.lts.id
      node_type_id  = data.databricks_node_type.smallest.id
      num_workers   = 0

      spark_conf = {
        "spark.databricks.cluster.profile" = "singleNode"
        "spark.master"                     = "local[*]"
      }

      custom_tags = {
        "ResourceClass" = "SingleNode"
      }

      data_security_mode = "SINGLE_USER"
      single_user_name   = var.ci_application_id
    }
  }

  task {
    task_key        = "bronze"
    job_cluster_key = "pipeline"

    depends_on {
      task_key = "seed"
    }

    notebook_task {
      notebook_path = databricks_notebook.layer["bronze"].path
      base_parameters = {
        catalog         = var.env
        landing_url     = var.landing_url
        checkpoints_url = var.checkpoints_url
      }
    }
  }

  # ORDER MATTERS HERE, AND NOT FOR THE REASON IT LOOKS LIKE.
  #
  # These blocks are listed bronze -> gold -> silver, which reads wrong. Execution
  # order is NOT set by block order - it comes from the depends_on blocks below,
  # and is still bronze -> silver -> gold.
  #
  # The listing order is alphabetical because that is how the Databricks API
  # returns tasks when Terraform reads the job back. `task` is a LIST, matched
  # positionally, so a config ordered bronze/silver/gold against an API response
  # ordered bronze/gold/silver produces a diff on every single plan - one that
  # "applies" successfully and reappears immediately.
  #
  # A perpetual diff is worse than it sounds in CI: no run is ever clean, so
  # "no changes" stops carrying information and people stop reading plans.
  task {
    task_key        = "gold"
    job_cluster_key = "pipeline"

    depends_on {
      task_key = "silver"
    }

    notebook_task {
      notebook_path   = databricks_notebook.layer["gold"].path
      base_parameters = { catalog = var.env }
    }
  }

  # Listed between gold and silver only because task blocks must appear in the
  # order the API returns them - alphabetically by task_key. Execution order is
  # seed -> bronze -> silver -> gold, set by the depends_on blocks.
  task {
    task_key        = "seed"
    job_cluster_key = "pipeline"

    notebook_task {
      notebook_path = databricks_notebook.layer["seed_landing"].path
      base_parameters = {
        landing_url = var.landing_url
        # Bump this between runs to simulate new files arriving. Auto Loader
        # should pick up ONLY the new batch - that is the whole demonstration.
        batch         = var.seed_batch
        total_batches = "4"
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
      notebook_path   = databricks_notebook.layer["silver"].path
      base_parameters = { catalog = var.env }
    }
  }

  run_as {
    service_principal_name = var.ci_application_id
  }

  email_notifications {
    no_alert_for_skipped_runs = true
  }
}
