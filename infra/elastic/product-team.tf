resource "ec_observability_project" "product_team" {
  name      = "${var.project_name}-product-team"
  region_id = var.project_region_id
}

# ── Cross-Project Search: product team → platform ─────────────────────────────
#
# PATCHes the product team project to link the platform project as a CPS source.
# After linking, ES|QL queries from the product team can use:
#   FROM platform:traces-generic.otel-default | ...
#
# The PATCH goes to the *origin* project (product team — the one querying).
# The linked body names the *source* project (platform — the data).

resource "terraform_data" "cross_project_search" {
  depends_on = [
    ec_observability_project.main,
    ec_observability_project.product_team,
  ]

  triggers_replace = {
    main_project_id         = ec_observability_project.main.id
    product_team_project_id = ec_observability_project.product_team.id
  }

  input = {
    product_team_project_id = ec_observability_project.product_team.id
    ec_api_key = var.ec_api_key
    request_body = jsonencode({
      linked = {
        projects = {
          (ec_observability_project.main.id) = { type = "observability" }
        }
      }
    })
  }

  provisioner "local-exec" {
    command = <<-EOT
      command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required"; exit 1; }
      [ -z "$EC_API_KEY" ] && { echo "ERROR: EC_API_KEY not set"; exit 1; }

      echo "==> Linking platform project to product team via CPS..."

      RESP=$(curl -s -w "\n%%{http_code}" -X PATCH \
        "https://api.elastic-cloud.com/api/v1/serverless/projects/observability/${self.input.product_team_project_id}" \
        -H "Authorization: ApiKey $EC_API_KEY" \
        -H "Content-Type: application/json" \
        -d '${self.input.request_body}')

      HTTP_CODE=$(echo "$RESP" | tail -1)
      BODY=$(echo "$RESP" | head -n -1)
      echo "==> HTTP $HTTP_CODE: $BODY"

      [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ] || {
        echo "ERROR: CPS link failed with HTTP $HTTP_CODE"
        exit 1
      }
      echo "==> CPS link complete. ✓"
    EOT

    environment = {
      EC_API_KEY = var.ec_api_key
    }
  }

  # Remove the CPS link before the projects are destroyed.
  # Without this, the platform project deletion fails with 400
  # "project is in use by linked origin projects".
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "==> Removing CPS link from product team project..."
      RESP=$(curl -s -w "\n%%{http_code}" -X PATCH \
        "https://api.elastic-cloud.com/api/v1/serverless/projects/observability/${self.input.product_team_project_id}" \
        -H "Authorization: ApiKey ${self.input.ec_api_key}" \
        -H "Content-Type: application/json" \
        -d '{"linked":{"projects":{}}}')
      HTTP_CODE=$(echo "$RESP" | tail -1)
      BODY=$(echo "$RESP" | head -n -1)
      echo "==> HTTP $HTTP_CODE: $BODY"
      [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "404" ] || {
        echo "ERROR: CPS removal failed with HTTP $HTTP_CODE"
        exit 1
      }
      echo "==> CPS link removed. ✓"
    EOT
  }
}
