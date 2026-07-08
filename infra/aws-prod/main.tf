# ── infra/aws-prod ────────────────────────────────────────────────────────────
# A separate module (separate state) from infra/aws on purpose.
#
# infra/aws is the Universal Profiling host: it hard-requires Fleet vars and its
# apply-profiling-host flow runs an *untargeted* `terraform destroy` before each
# rebuild. Folding the prod app host into that state would mean rebuilding the
# profiling host also destroys prod. Keeping prod in its own module isolates the
# two lifecycles completely — `apply-prod-host` / `teardown-prod` touch only this.

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "local" {}
}

provider "aws" {
  region = var.aws_region
}
