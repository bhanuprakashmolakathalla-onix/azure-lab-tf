# The serving tier: a container that reads the gold layer and shows it to people.
#
# ---------------------------------------------------------------------------
# THE IDENTITY CHAIN, which is the only genuinely interesting part
#
#   azurerm_user_assigned_identity        an Azure identity for the container
#          |  client_id
#          v
#   databricks_service_principal          the SAME identity, known to Databricks
#          |
#          +-- assigned into the dev workspace       (may enter)
#          +-- CAN_USE on the SQL warehouse          (may run queries)
#          +-- USE CATALOG / USE SCHEMA / SELECT     (may read gold)
#
# Four separate gates again, exactly as on Day 4 - existence, assignment,
# compute permission, data privilege. The container holds no secret; it asks
# Azure for a token at runtime and Databricks recognises the caller.
# ---------------------------------------------------------------------------

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

resource "azurerm_resource_group" "serving" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# --- Registry -------------------------------------------------------------
#
# Basic tier: 10 GiB, no geo-replication, ~Rs 350/month. The tiers differ in
# storage, throughput and replication, not in features you need here.
#
# admin_enabled stays FALSE. Turning it on creates a username/password pair that
# works from anywhere - the exact kind of long-lived credential this whole repo
# has avoided. The container pulls with its managed identity instead.
resource "azurerm_container_registry" "acr" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.serving.name
  location            = azurerm_resource_group.serving.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.tags
}

# --- The application's identity -------------------------------------------
#
# USER-assigned rather than system-assigned, deliberately.
#
# A system-assigned identity is created and destroyed with the container app, so
# its object id changes on every replacement - and every grant referencing it
# would have to be reissued. That is the Day 7 flip-flop in a new costume.
#
# A user-assigned identity outlives the app, so the Databricks registration and
# all four gates below stay valid across redeploys.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-taxi-api"
  resource_group_name = azurerm_resource_group.serving.name
  location            = azurerm_resource_group.serving.location
  tags                = var.tags
}

# AcrPull, not Contributor. The app reads one image and never writes.
resource "azurerm_role_assignment" "acr_pull" {
  scope                            = azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.app.principal_id
  skip_service_principal_aad_check = true
}

# --- Container Apps -------------------------------------------------------

# The environment needs somewhere to send logs. Small ingest here is effectively
# free; the trap is leaving verbose logging on in a chatty app, where Log
# Analytics quietly becomes the largest line on the bill.
resource "azurerm_log_analytics_workspace" "logs" {
  name                = "log-taxi-api"
  resource_group_name = azurerm_resource_group.serving.name
  location            = azurerm_resource_group.serving.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_container_app_environment" "env" {
  name                       = "cae-lab01"
  resource_group_name        = azurerm_resource_group.serving.name
  location                   = azurerm_resource_group.serving.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id
  tags                       = var.tags
}

resource "azurerm_container_app" "api" {
  name                         = "ca-taxi-api"
  resource_group_name          = azurerm_resource_group.serving.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  # The registry block is how the app authenticates its own image pull. Naming
  # the identity here is what avoids an ACR admin password.
  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # SCALE TO ZERO. With min_replicas = 0 the app costs nothing when nobody is
    # calling it - the property that makes Container Apps the right choice over
    # App Service for something used occasionally.
    #
    # The cost is a cold start on the first request after idle. For an API that
    # already waits on a serverless warehouse, that is noise.
    min_replicas = 0
    max_replicas = 2

    container {
      name   = "api"
      image  = "${azurerm_container_registry.acr.login_server}/taxi-api:${var.image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "DATABRICKS_SERVER_HOSTNAME"
        value = replace(data.terraform_remote_state.workspace.outputs.workspace_hosts["dev"], "https://", "")
      }

      env {
        name  = "DATABRICKS_HTTP_PATH"
        value = local.serving_http_path
      }

      # How DefaultAzureCredential knows WHICH identity to use. A container app
      # can carry several; without this it has to guess, and guesses wrong.
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.app.client_id
      }

      env {
        name  = "CATALOG"
        value = var.catalog
      }

      env {
        name  = "SERVING_COMPUTE"
        value = var.serving_compute == "warehouse" ? "a serverless SQL warehouse" : "a single-node cluster"
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8000
        path      = "/health"
      }

      readiness_probe {
        transport = "HTTP"
        port      = 8000
        path      = "/health"
      }
    }
  }

  depends_on = [azurerm_role_assignment.acr_pull]
}
