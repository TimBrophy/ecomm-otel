variable "aws_region" {
  description = "AWS region"
  default     = "eu-central-1"
}

variable "fleet_url" {
  description = "Fleet server URL (FLEET_URL in .env)"
}

variable "fleet_enrollment_token" {
  description = "Fleet enrollment token for the profiling host policy (written to .env by apply-aws)"
  sensitive   = true
}

variable "instance_type" {
  description = "EC2 instance type — t3.medium minimum for Universal Profiling eBPF"
  default     = "t3.medium"
}

variable "key_pair_name" {
  description = "EC2 key pair name for SSH access (optional). Set KEY_PAIR_NAME in .env."
  default     = ""
}

variable "agent_version" {
  description = "Elastic Agent version to install. Set ELASTIC_AGENT_VERSION in .env."
  default     = "9.4.3"
}

# ── Required Elastic SA AWS tagging ──────────────────────────────────────────
variable "team" {
  description = "Your SA team name. Set TEAM in .env. See: https://elasticco.atlassian.net/wiki/spaces/PRES/pages/673415186"
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
