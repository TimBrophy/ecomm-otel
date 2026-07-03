resource "ec_observability_project" "main" {
  name      = var.project_name
  region_id = var.project_region_id
}

# Note: the mOTLP ingest API key cannot be created via Terraform because the
# elasticstack provider is configured with an EC (cloud-level) API key, and
# Serverless blocks cloud keys from calling /_security/api_key. The key is
# provisioned by demo.sh apply via provision_ingest_key() which uses
# username/password credentials obtained after reset-credentials.
