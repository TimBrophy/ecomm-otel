variable "aws_region" {
  description = "AWS region"
  default     = "eu-central-1"
}

variable "prod_instance_type" {
  description = "EC2 instance type. Full stack (7 services + Kafka + Zookeeper + collector) needs ~8GB — t3.large minimum."
  default     = "t3.large"
}

variable "prod_repo_url" {
  description = "Git URL the prod host clones and builds from. Must be reachable from EC2 (public, or include a PAT/deploy token). Set PROD_REPO_URL in .env or let demo.sh derive it from 'git remote get-url origin'."
}

variable "prod_repo_ref" {
  description = "Git ref (branch, tag, or SHA) the prod host checks out."
  default     = "main"
}

variable "elastic_ingest_endpoint" {
  description = "Managed OTLP ingest endpoint (ELASTIC_INGEST_ENDPOINT in .env). The on-host collector forwards here."
}

variable "elastic_ingest_api_key" {
  description = "Unrestricted mOTLP ingest API key (ELASTIC_INGEST_API_KEY in .env). Passed via user_data — see note in ec2.tf about Secrets Manager as the hardening path."
  sensitive   = true
}

variable "key_pair_name" {
  description = "EC2 key pair for SSH (optional — SSM is the primary access path). Set KEY_PAIR_NAME in .env."
  default     = ""
}

# ── Required Elastic SA AWS tagging ──────────────────────────────────────────
variable "team" {
  description = "Your SA team name. Set TEAM in .env."
  default     = "emea_north_area"
}

variable "project" {
  description = "Your Elastic email username with dots removed. Set PROJECT in .env."
  default     = "timothybrophy"
}

variable "keep_until" {
  description = "Resource expiry date in YYYY-MM-DD format, max 13 months out. Set KEEP_UNTIL in .env."
  default     = "2026-08-02"
}
