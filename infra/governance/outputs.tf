output "ci_sp_id" {
  description = "Numeric Databricks id of the CI service principal. unity-catalog needs this for workspace assignments; grants key on the application id instead."
  value       = databricks_service_principal.ci.id
}

output "ci_application_id" {
  value = databricks_service_principal.ci.application_id
}

output "budget_name" {
  value = azurerm_consumption_budget_subscription.lab.name
}
