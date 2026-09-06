output "job_id" {
  value = databricks_job.medallion.id
}

output "job_url" {
  value = databricks_job.medallion.url
}

output "node_type" {
  value = data.databricks_node_type.smallest.id
}
