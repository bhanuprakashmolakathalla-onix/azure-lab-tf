# The serving tier: a container that reads the gold layer and shows it to people.
#
# ---------------------------------------------------------------------------
# THE IDENTITY CHAIN, which is the genuinely interesting part
#
#   azurerm_user_assigned_identity        an Azure identity for the container
#          |  client_id
#          v
#   databricks_service_principal          the SAME identity, known to Databricks
#          |
#          +-- assigned into the workspace           (may enter)
#          +-- CAN_USE / CAN_RESTART on compute      (may run queries)
#          +-- USE CATALOG / USE SCHEMA / SELECT     (may read gold)
#
# Four separate gates - existence, assignment, compute permission, data
# privilege. The container holds no secret; it asks Azure for a token at runtime
# and Databricks recognises the caller.
#
# ---------------------------------------------------------------------------
# THE NETWORK SHAPE, which is what "public app, private everything" means
#
#   internet -> Container Apps ingress (public FQDN, IP-restricted)
#                    |
#                    v
#            snet-apps 10.10.4.0/23   <- workloads run IN the transit VNet
#                    |
#                    +-> ACR private endpoint          (image pull)
#                    +-> Databricks frontend PE 10.10.1.4 (queries)
#
# The only public surface is the ingress FQDN. Everything the app TALKS TO is
# reached over private addresses inside the VNet.
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

data "terraform_remote_state" "network" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "network.tfstate"
    use_azuread_auth     = true
  }
}

locals {
  ws  = data.terraform_remote_state.workspace.outputs
  net = data.terraform_remote_state.network.outputs
}

resource "azurerm_resource_group" "serving" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# --- Registry -------------------------------------------------------------
#
# PREMIUM, and only because private endpoints require it. Basic would be a fifth
# of the cost and identical in every feature this app uses.
#
# admin_enabled stays FALSE. Turning it on creates a username/password pair that
# works from anywhere - the exact long-lived credential this repo has avoided
# throughout. The container pulls with its managed identity instead.
#
# HONEST LIMITATION, stated rather than hidden: public_network_access stays
# ENABLED. `az acr build` runs on ACR Tasks infrastructure, which lives outside
# your VNet and cannot reach a registry whose public endpoint is closed. The
# production answer is a Premium DEDICATED AGENT POOL injected into the VNet,
# which is more cost and more moving parts than a one-day lab warrants.
#
# What the private endpoint below still buys: the container app's image PULL -
# the path that runs continuously, on every scale-out - resolves to a private
# address and never leaves the VNet. The public endpoint remains, but it is
# Entra-authenticated with no keys to leak.
resource "azurerm_container_registry" "acr" {
  name                          = var.acr_name
  resource_group_name           = azurerm_resource_group.serving.name
  location                      = azurerm_resource_group.serving.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = true
  tags                          = var.tags
}

# privatelink.azurecr.io - same interception mechanism as the Databricks zones.
# The name is not ours to choose; it is what Azure's public CNAME chain points
# at, and matching it exactly is what makes the private resolution happen.
resource "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = local.net.transit_resource_group
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr_transit" {
  name                  = "link-transit"
  resource_group_name   = local.net.transit_resource_group
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  virtual_network_id    = local.net.transit_vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

# An ACR private endpoint takes TWO addresses - the registry API and a separate
# data endpoint for blob download. private_dns_zone_group writes both A records;
# cover only the first and pulls fail after authenticating, which reads like a
# permissions problem and is not one.
resource "azurerm_private_endpoint" "acr" {
  name                = "pe-${var.acr_name}"
  resource_group_name = azurerm_resource_group.serving.name
  location            = azurerm_resource_group.serving.location
  subnet_id           = local.net.transit_privatelink_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-acr"
    private_connection_resource_id = azurerm_container_registry.acr.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-acr"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr.id]
  }
}

# --- The application's identity -------------------------------------------
#
# USER-assigned rather than system-assigned, deliberately.
#
# A system-assigned identity is created and destroyed with the container app, so
# its object id changes on every replacement - and every grant referencing it
# would have to be reissued. A user-assigned identity outlives the app, so the
# Databricks registration and all four gates stay valid across redeploys.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-fashion-app"
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

# The environment needs somewhere to send logs. Small ingest is effectively
# free; the trap is leaving verbose logging on in a chatty app, where Log
# Analytics quietly becomes the largest line on the bill.
resource "azurerm_log_analytics_workspace" "logs" {
  name                = "log-fashion-app"
  resource_group_name = azurerm_resource_group.serving.name
  location            = azurerm_resource_group.serving.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# VNET-INJECTED. This is the line that makes "public app, private everything"
# true rather than aspirational.
#
#   infrastructure_subnet_id        replicas run in YOUR subnet, so they can
#                                   reach private endpoints and are governed by
#                                   your network - not in a Microsoft-managed
#                                   network with no route to 10.10.1.4
#
#   internal_load_balancer_enabled  FALSE deliberately. True would put ingress
#     = false                       on a private IP too, and you asked for the
#                                   app to be publicly reachable. The workloads
#                                   are private; the front door is not.
#
# The subnet must be /23 or larger and delegated to Microsoft.App/environments -
# both already true of snet-apps. Container Apps consumes addresses far faster
# than replica count suggests, which is why the network module sized it /23
# rather than /24.
resource "azurerm_container_app_environment" "env" {
  name                           = "cae-fashion"
  resource_group_name            = azurerm_resource_group.serving.name
  location                       = azurerm_resource_group.serving.location
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.logs.id
  infrastructure_subnet_id       = local.net.apps_subnet_id
  internal_load_balancer_enabled = false
  tags                           = var.tags
}

resource "azurerm_container_app" "api" {
  name                         = "ca-fashion-app"
  resource_group_name          = azurerm_resource_group.serving.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  # How the app authenticates its own image pull. Naming the identity here is
  # what avoids an ACR admin password.
  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    transport        = "auto"

    # THE PUBLIC SURFACE, AND ITS ONLY GUARD.
    #
    # The FQDN is world-resolvable; this is what stops the world using it. One
    # allow rule means everything else is denied - Container Apps switches to
    # deny-by-default the moment a single Allow rule exists, so there is no
    # companion deny rule to write (and writing one would be a mistake).
    ip_security_restriction {
      name             = "allow-me"
      action           = "Allow"
      ip_address_range = "${var.allowed_source_ip}/32"
      description      = "Bhanu's laptop. Everything else is denied by omission."
    }

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
    # already waits on compute to wake, that is noise.
    min_replicas = 0
    max_replicas = 2

    container {
      name   = "api"
      image  = "${azurerm_container_registry.acr.login_server}/${var.image_name}:${var.image_tag}"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "DATABRICKS_SERVER_HOSTNAME"
        value = replace(local.ws.workspace_host, "https://", "")
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
        name  = "BRAND_NAME"
        value = var.brand_name
      }

      env {
        name  = "SERVING_COMPUTE"
        value = var.serving_compute == "warehouse" ? "a serverless SQL warehouse" : "a single-node cluster"
      }

      # Probes hit /health, which deliberately does NOT touch Databricks. A
      # probe that queried the warehouse would wake it on every check and the
      # platform probes constantly - the thing meant to report health would
      # prevent the warehouse from ever sleeping.
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
