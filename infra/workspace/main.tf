# Databricks workspace with no public path in or out.
#
# ---------------------------------------------------------------------------
# WHAT MAKES IT PRIVATE - four settings that only work together
#
#   custom_parameters.virtual_network_id     VNet injection: clusters run in YOUR
#                                            network, not a Databricks-managed one
#   custom_parameters.no_public_ip = true    secure cluster connectivity - nodes
#                                            get no public address at all
#   public_network_access_enabled = false    the workspace REST API and UI are
#                                            unreachable from the internet
#   network_security_group_rules_required    tell Databricks NOT to inject its
#     = "NoAzureDatabricksRules"             control-plane NSG rules, because
#                                            that traffic now goes over Private
#                                            Link instead
#
# Set the third without the private endpoints below and you lock yourself out of
# your own workspace with no way back except turning it off again.
#
# CONSEQUENCE, stated plainly: the databricks Terraform provider, the CLI, and
# the web UI are all unreachable from outside this VNet. GitHub-hosted runners
# are outside it. Everything that touches Databricks now runs from the jumpbox
# or from a self-hosted runner - which is precisely why regulated environments
# run their own runners.
# ---------------------------------------------------------------------------

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

data "terraform_remote_state" "foundation" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "foundation.tfstate"
    use_azuread_auth     = true
  }
}

locals {
  net = data.terraform_remote_state.network.outputs
  fnd = data.terraform_remote_state.foundation.outputs
}

resource "azurerm_databricks_workspace" "this" {
  name                = var.workspace_name
  resource_group_name = local.fnd.resource_group_name
  location            = local.fnd.location
  sku                 = "premium" # Unity Catalog and Private Link are premium-only

  managed_resource_group_name = "databricks-rg-${var.workspace_name}"

  # No public path to the workspace API or UI.
  public_network_access_enabled = false

  # Databricks would normally inject NSG rules permitting control-plane traffic
  # over the internet. With back-end Private Link that traffic is private, so
  # those rules would be permitting a path that should no longer exist.
  network_security_group_rules_required = "NoAzureDatabricksRules"

  custom_parameters {
    # VNET INJECTION. Clusters launch into subnets you own, governed by your NSG,
    # egressing through your NAT gateway. Cannot be added to an existing
    # workspace - this is why the old workspaces were destroyed rather than
    # modified.
    virtual_network_id = local.net.workspace_vnet_id

    # Databricks calls these public/private. Under secure cluster connectivity
    # neither carries a public IP; they are the host and container networks, and
    # every node consumes one address in each.
    public_subnet_name  = local.net.host_subnet_name
    private_subnet_name = local.net.container_subnet_name

    # The ASSOCIATION ids, not the NSG id. An easy and confusing mistake -
    # Azure accepts an NSG id here and then fails at workspace creation.
    public_subnet_network_security_group_association_id  = local.net.host_nsg_association_id
    private_subnet_network_security_group_association_id = local.net.container_nsg_association_id

    # Secure cluster connectivity. No public IPs on any node.
    no_public_ip = true
  }

  tags = var.tags
}

# --- Back-end private endpoint --------------------------------------------
#
# Cluster nodes -> control plane, from INSIDE the workspace VNet. This is what
# replaces the internet path the NSG rules used to permit.
resource "azurerm_private_endpoint" "backend" {
  name                = "pe-${var.workspace_name}-backend"
  resource_group_name = local.fnd.resource_group_name
  location            = local.fnd.location
  subnet_id           = local.net.workspace_privatelink_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-backend"
    private_connection_resource_id = azurerm_databricks_workspace.this.id
    subresource_names              = ["databricks_ui_api"]
    is_manual_connection           = false
  }

  # The WORKSPACE zone. This is the half of the two-zone split that serves
  # clusters.
  private_dns_zone_group {
    name                 = "dns-backend"
    private_dns_zone_ids = [local.net.dns_zone_ids.databricks_backend]
  }

  # SERIALISED, and this is not optional.
  #
  # Attaching a private endpoint UPDATES the workspace resource, and the
  # Databricks API rejects concurrent updates to one workspace with
  # ConcurrentUpdateError. Terraform parallelises to 10 by default and nothing in
  # the config tells it these three conflict - they are independent resources
  # that happen to mutate a shared parent.
  #
  # The chain browser_auth -> backend -> frontend forces one at a time. Roughly
  # six minutes instead of two, and it actually completes.
  depends_on = [azurerm_private_endpoint.browser_auth]
}

# --- Front-end private endpoint -------------------------------------------
#
# You / the jumpbox / the app -> control plane, from the TRANSIT VNet.
#
# Same sub-resource as the back-end, same hostname, DIFFERENT private IP - which
# is the entire reason there are two DNS zones. One zone cannot hold two records
# for one name.
resource "azurerm_private_endpoint" "frontend" {
  name                = "pe-${var.workspace_name}-frontend"
  resource_group_name = local.net.transit_resource_group
  location            = local.fnd.location
  subnet_id           = local.net.transit_privatelink_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-frontend"
    private_connection_resource_id = azurerm_databricks_workspace.this.id
    subresource_names              = ["databricks_ui_api"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-frontend"
    private_dns_zone_ids = [local.net.dns_zone_ids.databricks_frontend]
  }

  # Third in the chain. See the note on the back-end endpoint.
  depends_on = [azurerm_private_endpoint.backend]
}

# --- Browser authentication endpoint --------------------------------------
#
# The one with no GCP analogue, and the one everybody forgets.
#
# Signing in to the workspace UI redirects to Microsoft Entra, which then calls
# BACK to the Databricks web app. With no public path that callback cannot land,
# so the login spins forever - a failure that looks like a broken workspace
# rather than a missing endpoint.
#
# One per region per tenant, and it belongs in the transit VNet with the humans.
resource "azurerm_private_endpoint" "browser_auth" {
  name                = "pe-${var.workspace_name}-browserauth"
  resource_group_name = local.net.transit_resource_group
  location            = local.fnd.location
  subnet_id           = local.net.transit_privatelink_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-browserauth"
    private_connection_resource_id = azurerm_databricks_workspace.this.id
    subresource_names              = ["browser_authentication"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-browserauth"
    private_dns_zone_ids = [local.net.dns_zone_ids.databricks_frontend]
  }
}
