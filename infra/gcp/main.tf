terraform {
  required_version = ">= 1.7"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }
  backend "gcs" {
    bucket = "ecomm-otel-demo-state"
    prefix = "gcp/terraform.tfstate"
  }
}

provider "google" {
  project = "elastic-sa"
  region  = "europe-west3"
}

provider "google-beta" {
  project = "elastic-sa"
  region  = "europe-west3"
}
