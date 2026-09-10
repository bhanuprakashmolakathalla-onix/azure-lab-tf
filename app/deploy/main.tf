# The serving tier: two sites over one lakehouse.
#
# ---------------------------------------------------------------------------
# WHAT GETS BUILT
#
#   ca-fashion-shop      the storefront. Browse, choose a size, place an order.
#   ca-fashion-console   the operations console. Work the order book, read the
#                        marts, see what the pipeline quarantined.
#
# ONE image, TWO container apps, TWO identities. The image is shared because the
# code is; the identities are separate because the privileges are:
#
#                        gold    silver   ops
#   shop identity        read      -      read + write + create
#   console identity     read    read     read + write
#
# The shop can take an order and cannot look at the silver layer. The console
# can see everything the pipeline produced and cannot create a table. Neither
# holds a secret - each asks Azure for a token at runtime and Databricks
# recognises the caller.
#
# ---------------------------------------------------------------------------
# THE NETWORK SHAPE, which is what "public app, private everything" means
#
#   internet -> Container Apps ingress (public FQDN, IP-restricted)
#                    |
#                    v
#            snet-apps 10.10.4.0/23   <- workloads run IN the transit VNet
#                    |
#                    +-> Databricks frontend private endpoint (queries)
#
# The only public surface is the two ingress FQDNs, and each is locked to one
# source address. Everything the apps TALK TO is reached over private addresses
# inside the VNet.
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

  # Premium is the only SKU that supports private endpoints. Everything else the
  # two apps need is in Basic.
  acr_private = var.acr_sku == "Premium"
}

resource "azurerm_resource_group" "serving" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# --- Registry -------------------------------------------------------------
#
# BASIC by default, and that is a deliberate change from Premium.
#
# Premium buys exactly one thing here - a private endpoint for the image pull -
# and costs roughly ten times as much per day. For a lab that is built in the
# morning and destroyed in the evening, that is the single largest avoidable
# line on the bill, spent on closing a path that is already Entra-authenticated
# with no keys to leak.
#
# Set acr_sku = "Premium" and the private endpoint below appears. The variable
# exists because this IS the right call in production and the wrong one for a
# day: an image pull happens on every scale-out, continuously, and in a regulated
# environment it should not traverse a public endpoint even an authenticated one.
#
# admin_enabled stays FALSE either way. Turning it on creates a username and
# password pair that works from anywhere - the exact long-lived credential this
# repo has avoided throughout. Both apps pull with their managed identity.
#
# HONEST LIMITATION even on Premium: public_network_access stays enabled,
# because `az acr build` runs on ACR Tasks infrastructure outside your VNet and
# cannot reach a registry whose public endpoint is closed. The production answer
# is a dedicated agent pool injected into the VNet, which is more cost and more
# moving parts than a one-day lab warrants.
resource "azurerm_container_registry" "acr" {
  name                          = var.acr_name
  resource_group_name           = azurerm_resource_group.serving.name
  location                      = azurerm_resource_group.serving.location
  sku                           = var.acr_sku
  admin_enabled                 = false
  public_network_access_enabled = true
  tags                          = var.tags
}

# privatelink.azurecr.io - same interception mechanism as the Databricks zones.
# The name is not ours to choose; it is what Azure's public CNAME chain points
# at, and matching it exactly is what makes private resolution happen.
resource "azurerm_private_dns_zone" "acr" {
  count = local.acr_private ? 1 : 0

  name                = "privatelink.azurecr.io"
  resource_group_name = local.net.transit_resource_group
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr_transit" {
  count = local.acr_private ? 1 : 0

  name                  = "link-transit"
  resource_group_name   = local.net.transit_resource_group
  private_dns_zone_name = azurerm_private_dns_zone.acr[0].name
  virtual_network_id    = local.net.transit_vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

# An ACR private endpoint takes TWO addresses - the registry API and a separate
# data endpoint for blob download. private_dns_zone_group writes both A records;
# cover only the first and pulls fail after authenticating, which reads like a
# permissions problem and is not one.
resource "azurerm_private_endpoint" "acr" {
  count = local.acr_private ? 1 : 0

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
    private_dns_zone_ids = [azurerm_private_dns_zone.acr[0].id]
  }
}

# --- The applications' identities -----------------------------------------
#
# USER-assigned rather than system-assigned, deliberately.
#
# A system-assigned identity is created and destroyed with the container app, so
# its object id changes on every replacement - and every grant referencing it
# would have to be reissued. A user-assigned identity outlives the app, so the
# Databricks registration and all four gates stay valid across redeploys.
#
# TWO of them, one per site. It would be less code to share one, and sharing it
# would mean the public storefront held every privilege the internal console
# does. An identity is the smallest unit of blast radius available here, and
# spending a second one is cheap.
resource "azurerm_user_assigned_identity" "app" {
  for_each = toset(["shop", "console"])

  name                = "id-fashion-${each.key}"
  resource_group_name = azurerm_resource_group.serving.name
  location            = azurerm_resource_group.serving.location
  tags                = var.tags
}

# AcrPull, not Contributor. The apps read one image and never write.
resource "azurerm_role_assignment" "acr_pull" {
  for_each = azurerm_user_assigned_identity.app

  scope                            = azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = each.value.principal_id
  skip_service_principal_aad_check = true
}

# --- The bag signing key --------------------------------------------------
#
# The storefront keeps the shopping bag in a signed cookie rather than a table -
# see app/src/cart.py for why. The signature needs a key that is the SAME across
# replicas and across restarts, or a bag vanishes whenever the app scales.
#
# Generated here rather than typed anywhere: it lands in state, which lives in a
# storage account with shared keys disabled and Entra-only access, and it is
# never printed. If it were a variable someone would eventually commit it.
resource "random_password" "cart_secret" {
  length  = 48
  special = false
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
#     = false                       on a private IP too, and both sites are meant
#                                   to be reachable from a laptop. The workloads
#                                   are private; the front doors are not.
#
# The subnet must be /23 or larger and delegated to Microsoft.App/environments -
# both already true of snet-apps. Container Apps consumes addresses far faster
# than replica count suggests, which is why the network module sized it /23
# rather than /24.
#
# ONE environment for both apps. An environment is the network and logging
# boundary, not the security boundary - that is the identity - so a second one
# would buy nothing and cost another subnet.
resource "azurerm_container_app_environment" "env" {
  name                           = "cae-fashion"
  resource_group_name            = azurerm_resource_group.serving.name
  location                       = azurerm_resource_group.serving.location
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.logs.id
  infrastructure_subnet_id       = local.net.apps_subnet_id
  internal_load_balancer_enabled = false
  tags                           = var.tags
}

locals {
  apps = {
    shop = {
      name  = "ca-fashion-shop"
      role  = "shop"
      brand = var.brand_name
    }
    console = {
      name  = "ca-fashion-console"
      role  = "console"
      brand = var.brand_name
    }
  }
}

resource "azurerm_container_app" "site" {
  for_each = local.apps

  name                         = each.value.name
  resource_group_name          = azurerm_resource_group.serving.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app[each.key].id]
  }

  # How the app authenticates its own image pull. Naming the identity here is
  # what avoids an ACR admin password.
  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.app[each.key].id
  }

  secret {
    name  = "cart-secret"
    value = random_password.cart_secret.result
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    transport        = "auto"

    # THE PUBLIC SURFACE, AND ITS ONLY GUARD.
    #
    # The FQDN is world-resolvable; this is what stops the world using it.
    # Container Apps switches to deny-by-default the moment a single Allow rule
    # exists, so there is no companion deny rule to write - and writing one would
    # be a mistake, because a Deny alongside an Allow changes the evaluation from
    # "allowlist" to something nobody can reason about at 2am.
    #
    # The console needs this more than the shop does: it can cancel orders.
    dynamic "ip_security_restriction" {
      for_each = { for i, ip in var.allowed_source_ips : "allow-${i}" => ip }
      content {
        name             = ip_security_restriction.key
        action           = "Allow"
        ip_address_range = "${ip_security_restriction.value}/32"
        description      = "Permitted operator address. Everything else is denied by omission."
      }
    }

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # SCALE TO ZERO. With min_replicas = 0 an app costs nothing when nobody is
    # calling it - the property that makes Container Apps the right choice over
    # App Service for something used occasionally.
    #
    # The cost is a cold start on the first request after idle, and for the shop
    # that also means an empty catalogue cache and one warehouse wake-up. For a
    # site someone visits in bursts, that is the right trade.
    min_replicas = 0
    max_replicas = 1

    container {
      name   = "web"
      image  = "${azurerm_container_registry.acr.login_server}/${var.image_name}:${var.image_tag}"
      cpu    = 0.5
      memory = "1Gi"

      # WHICH SITE THIS IS. The image contains both; this one variable decides.
      env {
        name  = "APP_ROLE"
        value = each.value.role
      }

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
        value = azurerm_user_assigned_identity.app[each.key].client_id
      }

      env {
        name  = "CATALOG"
        value = var.catalog
      }

      env {
        name  = "BRAND_NAME"
        value = each.value.brand
      }

      # Shown in the console footer, so the person reading it knows whether a
      # slow page is a warehouse waking or a cluster booting.
      env {
        name  = "SERVING_COMPUTE"
        value = var.serving_compute == "warehouse" ? "a serverless SQL warehouse" : "a single-node cluster"
      }

      env {
        name        = "CART_SECRET"
        secret_name = "cart-secret"
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
