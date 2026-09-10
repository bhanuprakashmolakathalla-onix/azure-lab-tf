output "workspace_vnet_id" { value = azurerm_virtual_network.workspace.id }
output "transit_vnet_id" { value = azurerm_virtual_network.transit.id }

output "workspace_resource_group" { value = azurerm_resource_group.workspace.name }
output "transit_resource_group" { value = azurerm_resource_group.transit.name }

output "host_subnet_name" {
  description = "Databricks calls this the PUBLIC subnet. Under SCC nothing in it has a public IP."
  value       = azurerm_subnet.host.name
}
output "container_subnet_name" { value = azurerm_subnet.container.name }

output "host_nsg_association_id" {
  description = "azurerm_databricks_workspace wants the ASSOCIATION id, not the NSG id."
  value       = azurerm_subnet_network_security_group_association.host.id
}
output "container_nsg_association_id" { value = azurerm_subnet_network_security_group_association.container.id }

output "workspace_privatelink_subnet_id" { value = azurerm_subnet.workspace_privatelink.id }
output "transit_privatelink_subnet_id" { value = azurerm_subnet.transit_privatelink.id }
output "jumpbox_subnet_id" { value = azurerm_subnet.jumpbox.id }
output "apps_subnet_id" { value = azurerm_subnet.apps.id }

output "dns_zone_ids" {
  description = "Two same-named Databricks zones plus storage. Endpoints attach via private_dns_zone_group."
  value = {
    databricks_frontend = azurerm_private_dns_zone.databricks_frontend.id
    databricks_backend  = azurerm_private_dns_zone.databricks_backend.id
    dfs                 = azurerm_private_dns_zone.dfs.id
    blob                = azurerm_private_dns_zone.blob.id
  }
}

output "nat_public_ip" {
  description = "Single egress address for all cluster traffic - what makes far-side allowlisting possible."
  value       = azurerm_public_ip.nat.ip_address
}
