# Scalars now, not maps - there is one workspace.
#
# NOTE these hosts are only RESOLVABLE from inside the VNets. From this laptop
# the name resolves to nothing and the API is unreachable; that is the design.

output "workspace_host" {
  description = "https://adb-....azuredatabricks.net - reachable only from the transit or workspace VNet."
  value       = "https://${azurerm_databricks_workspace.this.workspace_url}"
}

output "workspace_url" {
  value = azurerm_databricks_workspace.this.workspace_url
}

output "workspace_resource_id" {
  description = "ARM id. The databricks provider needs this as azure_workspace_resource_id."
  value       = azurerm_databricks_workspace.this.id
}

output "workspace_id" {
  description = "Numeric Databricks id - what workspace ASSIGNMENTS and catalog BINDINGS take."
  value       = azurerm_databricks_workspace.this.workspace_id
}

output "managed_resource_group_id" {
  value = azurerm_databricks_workspace.this.managed_resource_group_id
}

output "private_endpoint_ips" {
  description = "Useful when DNS misbehaves - confirms what the endpoints actually got."
  value = {
    backend      = azurerm_private_endpoint.backend.private_service_connection[0].private_ip_address
    frontend     = azurerm_private_endpoint.frontend.private_service_connection[0].private_ip_address
    browser_auth = azurerm_private_endpoint.browser_auth.private_service_connection[0].private_ip_address
  }
}
