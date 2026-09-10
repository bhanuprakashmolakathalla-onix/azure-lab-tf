# THE TWO LINKS. Both are HTTPS, both are world-resolvable, and both are
# reachable only from allowed_source_ip.

output "shop_url" {
  description = "The storefront. Browse, choose a size, place an order."
  value       = "https://${azurerm_container_app.site["shop"].ingress[0].fqdn}"
}

output "console_url" {
  description = "The operations console. Work the order book and read the marts."
  value       = "https://${azurerm_container_app.site["console"].ingress[0].fqdn}"
}

output "acr_login_server" { value = azurerm_container_registry.acr.login_server }

output "image_reference" {
  description = "What `az acr build` should produce. ONE image serves both sites."
  value       = "${azurerm_container_registry.acr.login_server}/${var.image_name}:${var.image_tag}"
}

output "app_client_ids" {
  description = "Managed identity client id = Databricks service principal application id, per site."
  value       = { for k, v in azurerm_user_assigned_identity.app : k => v.client_id }
}

output "serving_http_path" { value = local.serving_http_path }

output "serving_compute" { value = var.serving_compute }

output "acr_sku" {
  description = "Basic by default. Premium adds a private endpoint for image pulls and roughly ten times the daily cost."
  value       = var.acr_sku
}
