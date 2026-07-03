locals {
  required_tags = {
    Name        = "ecomm-otel-profiling-host"
    division    = "field"
    org         = "sa"
    team        = var.team
    project     = var.project
    keep-until  = var.keep_until
  }
}
