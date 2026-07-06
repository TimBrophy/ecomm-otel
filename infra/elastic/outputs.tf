output "elastic_project_id" {
  description = "Serverless project ID — add to .env as ELASTIC_PROJECT_ID"
  value       = ec_observability_project.main.id
}

output "elastic_endpoint" {
  description = "Elasticsearch endpoint — add to .env as ELASTIC_ENDPOINT"
  value       = ec_observability_project.main.endpoints.elasticsearch
}

output "kibana_endpoint" {
  description = "Kibana endpoint — add to .env as KIBANA_ENDPOINT"
  value       = ec_observability_project.main.endpoints.kibana
}

output "apm_endpoint" {
  description = "Legacy APM endpoint"
  value       = ec_observability_project.main.endpoints.apm
}

output "ingest_endpoint" {
  description = "Managed OTLP (mOTLP) ingest endpoint — add to .env as ELASTIC_INGEST_ENDPOINT"
  value       = ec_observability_project.main.endpoints.ingest
}

output "product_team_project_id" {
  description = "Product team Serverless project ID"
  value       = ec_observability_project.product_team.id
}

output "product_team_elastic_endpoint" {
  description = "Product team Elasticsearch endpoint"
  value       = ec_observability_project.product_team.endpoints.elasticsearch
}

output "product_team_kibana_endpoint" {
  description = "Product team Kibana endpoint"
  value       = ec_observability_project.product_team.endpoints.kibana
}

# Profiling deployment outputs are written to .env by demo.sh provision-profiling-deployment,
# not managed through Terraform (see profiling-deployment.tf comment for reasoning).

