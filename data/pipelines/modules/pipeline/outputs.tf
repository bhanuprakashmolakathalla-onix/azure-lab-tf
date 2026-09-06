output "job_id" {
  value = databricks_job.fashion.id
}

output "job_url" {
  value = databricks_job.fashion.url
}

output "node_type" {
  value = var.node_type_id
}
