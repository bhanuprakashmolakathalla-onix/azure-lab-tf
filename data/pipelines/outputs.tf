output "jobs" {
  description = "Both pipelines. Same code, same identity, different catalog."
  value = {
    dev  = { id = module.pipeline_dev.job_id, url = module.pipeline_dev.job_url }
    prod = { id = module.pipeline_prod.job_id, url = module.pipeline_prod.job_url }
  }
}

output "node_type" {
  value = module.pipeline_dev.node_type
}
