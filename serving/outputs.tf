output "app_url" {
  description = "Public HTTPS endpoint of the container app."
  value       = "https://${azurerm_container_app.api.ingress[0].fqdn}"
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "image_reference" {
  description = "What `az acr build` should produce."
  value       = "${azurerm_container_registry.acr.login_server}/taxi-api:${var.image_tag}"
}

output "app_client_id" {
  description = "Managed identity client id = Databricks service principal application id. One identity, two directories."
  value       = azurerm_user_assigned_identity.app.client_id
}

output "serving_http_path" {
  value = local.serving_http_path
}
