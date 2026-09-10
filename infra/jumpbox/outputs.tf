output "public_ip" { value = azurerm_public_ip.jumpbox.ip_address }
output "private_ip" { value = azurerm_network_interface.jumpbox.private_ip_address }
output "admin_username" { value = var.admin_username }

output "rdp_command" {
  description = "Windows: paste into Run. The jumpbox resolves the workspace via the TRANSIT DNS zone."
  value       = "mstsc /v:${azurerm_public_ip.jumpbox.ip_address}"
}

output "vm_id" {
  description = "For az vm deallocate / start - the cheapest control you have."
  value       = azurerm_windows_virtual_machine.jumpbox.id
}
