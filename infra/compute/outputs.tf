output "cluster_id" {
  value = databricks_cluster.single.id
}

output "cluster_name" {
  value = databricks_cluster.single.cluster_name
}

output "node_type" {
  description = "Pinned, not discovered. See the note in main.tf about why the data source was wrong here."
  value       = var.node_type_id
}

output "spark_version" {
  value = data.databricks_spark_version.lts.id
}

output "policy_id" {
  value = databricks_cluster_policy.lab.id
}
