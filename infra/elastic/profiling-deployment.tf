# ── Stateful ESS deployment for Universal Profiling ──────────────────────────
# Universal Profiling is not available in Elastic Cloud Serverless.
# The stateful deployment is created/destroyed via the EC REST API in demo.sh
# (provision-profiling-deployment / teardown commands) rather than Terraform,
# because all deployment templates in aws-eu-central-1 reference deprecated
# instance configurations that the EC API rejects at plan time.
#
# The ec_deployment Terraform resource is intentionally left absent here.
# Variables and .env keys written by demo.sh:
#   PROFILING_DEPLOYMENT_ID   PROFILING_KIBANA_URL
#   PROFILING_ES_URL          PROFILING_ES_USER
#   PROFILING_ES_PASSWORD     PROFILING_FLEET_URL
#   PROFILING_FLEET_ENROLLMENT_TOKEN
