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

  backend "local" {}
}

provider "ec" {
  apikey = var.ec_api_key
}

# elasticstack provider is configured after project creation using outputs.
# On first apply, run: terraform apply -target=ec_serverless_project.observability
# then terraform apply (full) to configure Kibana resources.
provider "elasticstack" {
  elasticsearch {
    endpoints = [var.elastic_endpoint]
    api_key   = var.ec_api_key
  }
  kibana {
    endpoints = [var.kibana_endpoint]
    api_key   = var.ec_api_key
  }
}
