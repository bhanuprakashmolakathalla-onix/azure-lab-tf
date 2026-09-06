output "cluster_id" {
  value = databricks_cluster.single.id
}

output "cluster_name" {
  value = databricks_cluster.single.cluster_name
}

output "node_type_chosen" {
  description = "Which SKU Databricks resolved. Worth reading - it is the answer to the Day 1 stockout."
  value       = data.databricks_node_type.smallest.id
}

output "spark_version" {
  value = data.databricks_spark_version.lts.id
}

output "policy_id" {
  value = databricks_cluster_policy.lab.id
}
