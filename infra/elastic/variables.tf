variable "ec_api_key" {
  description = "Elastic Cloud org-level API key (EC_API_KEY env var)"
  sensitive   = true
}

variable "kibana_api_key" {
  description = "Project-level unrestricted API key for Kibana saved objects (ELASTIC_INGEST_API_KEY). Falls back to ec_api_key when not set (pass 1 bootstrap)."
  sensitive   = true
  default     = ""
}

variable "elastic_endpoint" {
  description = "Elasticsearch endpoint (populated from project output after first apply)"
  default     = ""
}

variable "kibana_endpoint" {
  description = "Kibana endpoint (populated from project output after first apply)"
  default     = ""
}

variable "project_name" {
  description = "Elastic Cloud Serverless project name"
  default     = "ecomm-otel-demo"
}

variable "project_region_id" {
  description = "Elastic Cloud region — matches AWS eu-central-1"
  default     = "aws-eu-central-1"
}

variable "aws_region" {
  description = "AWS region (for cross-referencing)"
  default     = "eu-central-1"
}

variable "product_team_kibana_endpoint" {
  description = "Product team Kibana endpoint (populated by provision-product-team)"
  default     = ""
}

variable "product_team_es_endpoint" {
  description = "Product team Elasticsearch endpoint (populated by provision-product-team)"
  default     = ""
}

variable "product_team_api_key" {
  description = "Product team API key (minted by provision-product-team, stored in .env as PRODUCT_TEAM_API_KEY)"
  sensitive   = true
  default     = ""
}


