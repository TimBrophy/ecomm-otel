terraform {
  required_version = ">= 1.7"
  required_providers {
    ec = {
      source  = "elastic/ec"
      version = "~> 0.11"
    }
    elasticstack = {
      source  = "elastic/elasticstack"
      version = "~> 0.11"
    }
  }
  # Points at the GCS state written when the elastic module used the GCS backend
  backend "gcs" {
    bucket = "ecomm-otel-demo-state"
    prefix = "elastic/terraform.tfstate"
  }
}

variable "ec_api_key" { sensitive = true }

provider "ec" { apikey = var.ec_api_key }
provider "elasticstack" {
  elasticsearch { api_key = var.ec_api_key }
  kibana        { api_key = var.ec_api_key }
}
