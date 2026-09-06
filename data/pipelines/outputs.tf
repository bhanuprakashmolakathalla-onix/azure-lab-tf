output "job_id" { value = module.pipeline.job_id }
output "job_url" { value = module.pipeline.job_url }
output "node_type" { value = module.pipeline.node_type }

output "notebook_root" {
  description = "Where the notebooks live in the workspace, for opening them in the UI."
  value       = "/Shared/fashion"
}
