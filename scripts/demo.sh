#!/usr/bin/env bash
# demo.sh — local development tool
#
# Manages the Elastic Cloud project and local Docker stack.
# CI/CD (.github/workflows/deploy.yml) sends deployment markers to Elastic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANAGE_PROJECT="${HOME}/.claude/skills/cloud-manage-project/scripts/manage-project.py"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a; source "${ROOT_DIR}/.env"; set +a
fi

usage() {
  cat <<EOF
Usage: ./scripts/demo.sh <command>

Master commands (full stack):
  build               Full build: Elastic Cloud + Docker + AWS profiling host
  teardown            Full teardown: AWS + Elastic Cloud + Docker (one confirmation)

Granular commands:
  apply               Create Elastic Cloud project, provision ingest key, start Docker stack
  destroy             Stop Docker stack and destroy Elastic Cloud project
  apply-aws           Create Fleet policy + EC2 profiling host (requires apply first)
  destroy-aws         Destroy EC2 profiling host
  init                terraform init for infra/elastic
  plan                terraform plan for infra/elastic
  provision-fleet      (Re-)create Fleet agent policy + system integration only
  provision-connector  (Re-)create Slack API connector in Kibana
  refresh-key         Mint a fresh ingest API key and restart the collector
  provision-slos      (Re-)deploy SLOs to Kibana
  provision-alerts    (Re-)deploy Kibana alert rules from platform/alerts/
  provision-spaces    (Re-)deploy Kibana spaces from platform/spaces/
  provision-rbac      (Re-)deploy Kibana roles from platform/rbac/
  provision-product-team  Create product team project, configure CPS, deploy dashboards
  provision-team      Push team layer to main Kibana product-team space (legacy)
  provision-ml        Print ML anomaly detection job reference configs (UI-only in Serverless)
  trigger-incident    Enable realtime_fraud_detection flag (cascading latency + errors)
  reset               Reset demo flags to clean baseline
  test                Run smoke tests against local stack + Elastic Cloud

Cloud deployment is handled by CI/CD — see .github/workflows/deploy.yml.
To bootstrap the S3 state bucket (one-time): run scripts/bootstrap-state.sh

EOF
}

# ── .env helpers ──────────────────────────────────────────────────────────────

update_env() {
  local KEY="$1"
  local VALUE="$2"
  local ENV_FILE="${ROOT_DIR}/.env"
  if grep -q "^${KEY}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i.bak "s|^${KEY}=.*|${KEY}=${VALUE}|" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
  else
    # Ensure file ends with a newline before appending to prevent line concatenation
    [[ -s "${ENV_FILE}" ]] && [[ "$(tail -c1 "${ENV_FILE}" | wc -l)" -eq 0 ]] && \
      printf '\n' >> "${ENV_FILE}"
    echo "${KEY}=${VALUE}" >> "${ENV_FILE}"
  fi
  export "${KEY}=${VALUE}"
}

# ── Elastic ingest key provisioning ──────────────────────────────────────────
# Note: cannot use Terraform for this. Serverless blocks EC (cloud-level) API
# keys from calling /_security/api_key, so we reset credentials and use
# username/password to create an unrestricted key (no role_descriptors).

provision_ingest_key() {
  local PROJECT_ID="$1"

  echo "→ Resetting project admin credentials (saved to .elastic-credentials)"
  python3 "${MANAGE_PROJECT}" reset-credentials \
    --type observability --id "${PROJECT_ID}" --wait-seconds 30

  echo "→ Loading admin credentials"
  eval "$(python3 "${MANAGE_PROJECT}" load-credentials \
    --id "${PROJECT_ID}" --include-admin)"

  # Retry loop — credentials can take longer than 30s to propagate on a fresh project
  echo "→ Creating unrestricted ingest API key (retrying up to 90s)"
  local KEY_JSON ENCODED ATTEMPT=0
  while [[ ${ATTEMPT} -lt 9 ]]; do
    ATTEMPT=$((ATTEMPT + 1))
    KEY_JSON=$(curl -s -o /tmp/es_key_resp.json -w "%{http_code}" -X POST \
      "${ELASTICSEARCH_URL}/_security/api_key" \
      -H "Content-Type: application/json" \
      -u "${ELASTICSEARCH_USERNAME}:${ELASTICSEARCH_PASSWORD}" \
      -d '{"name":"ecomm-otel-ingest"}') || true

    if [[ "${KEY_JSON}" == "200" ]]; then
      ENCODED=$(python3 -c \
        "import sys,json; print(json.load(open('/tmp/es_key_resp.json'))['encoded'])" 2>/dev/null) || true
      if [[ -n "${ENCODED}" ]]; then
        break
      fi
    fi

    echo "  Attempt ${ATTEMPT}/9: got HTTP ${KEY_JSON} — waiting 10s for credential propagation"
    sleep 10
  done

  if [[ -z "${ENCODED:-}" ]]; then
    echo "✗ Failed to create ingest API key after ${ATTEMPT} attempts." >&2
    echo "  Last response: $(cat /tmp/es_key_resp.json 2>/dev/null)" >&2
    echo "  Try: ./scripts/demo.sh refresh-key once the cluster is ready." >&2
    exit 1
  fi

  update_env "ELASTIC_INGEST_API_KEY" "${ENCODED}"
  unset ELASTICSEARCH_USERNAME ELASTICSEARCH_PASSWORD
  rm -f /tmp/es_key_resp.json

  echo "✓ Ingest API key written to .env"
}

# ── Elastic resource provisioning ────────────────────────────────────────────

provision_pipelines() {
  echo "→ Provisioning Elasticsearch ingest pipelines"
  local PIPELINES_DIR="${ROOT_DIR}/platform/ingest-pipelines"
  local COUNT=0

  for PIPELINE_FILE in "${PIPELINES_DIR}"/*.json; do
    [[ -f "${PIPELINE_FILE}" ]] || continue
    local PIPELINE_NAME
    PIPELINE_NAME=$(basename "${PIPELINE_FILE}" .json)
    echo "  Applying pipeline: ${PIPELINE_NAME}"
    curl -sf -X PUT \
      "${ELASTICSEARCH_URL}/_ingest/pipeline/${PIPELINE_NAME}" \
      -H "Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}" \
      -H "Content-Type: application/json" \
      -d @"${PIPELINE_FILE}" > /dev/null
    echo "  ✓ ${PIPELINE_NAME}"
    COUNT=$((COUNT + 1))
  done

  [[ "${COUNT}" -eq 0 ]] && echo "  (no pipelines to provision)"
}

# ── SLO provisioning ─────────────────────────────────────────────────────────
# SLO definitions live in platform/slos/*.json.
# Created via Kibana Observability SLO API (/api/observability/slos).
# Re-running apply is idempotent: existing SLOs with the same name are skipped.

# ── Spaces provisioning ───────────────────────────────────────────────────────
# Space definitions live in platform/spaces/*.json.
# PUT /api/spaces/space/{id} is a true upsert — idempotent.

provision_spaces() {
  echo "→ Provisioning Kibana spaces"
  local SPACES_DIR="${ROOT_DIR}/platform/spaces"
  local KIBANA="${KIBANA_URL}"
  local AUTH="Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}"
  local COUNT=0

  for SPACE_FILE in "${SPACES_DIR}"/*.json; do
    [[ -f "${SPACE_FILE}" ]] || continue
    local SPACE_ID SPACE_NAME
    SPACE_ID=$(python3 -c "import json; print(json.load(open('${SPACE_FILE}'))['id'])" 2>/dev/null)
    SPACE_NAME=$(python3 -c "import json; print(json.load(open('${SPACE_FILE}'))['name'])" 2>/dev/null || echo "${SPACE_ID}")

    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /tmp/space_resp.json -w "%{http_code}" -X PUT \
      "${KIBANA}/api/spaces/space/${SPACE_ID}" \
      -H "${AUTH}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
      -d @"${SPACE_FILE}")

    if [[ "${HTTP_CODE}" == "404" ]]; then
      # Space doesn't exist yet — create it with POST
      HTTP_CODE=$(curl -s -o /tmp/space_resp.json -w "%{http_code}" -X POST \
        "${KIBANA}/api/spaces/space" \
        -H "${AUTH}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
        -d @"${SPACE_FILE}")
    fi

    if [[ "${HTTP_CODE}" =~ ^2 ]]; then
      echo "  ✓ space: ${SPACE_NAME} (${SPACE_ID})"
      COUNT=$((COUNT + 1))
    else
      echo "  ✗ space: ${SPACE_NAME} (HTTP ${HTTP_CODE})"
      python3 -m json.tool < /tmp/space_resp.json 2>/dev/null | head -5
    fi
  done

  [[ "${COUNT}" -eq 0 ]] && echo "  (no spaces to provision)"
  rm -f /tmp/space_resp.json
}

# ── RBAC provisioning ─────────────────────────────────────────────────────────
# Role definitions live in platform/rbac/*.json.
# Role name is derived from filename. PUT /api/security/role/{name} is a upsert.

provision_rbac() {
  echo "→ Provisioning Kibana roles"
  local RBAC_DIR="${ROOT_DIR}/platform/rbac"
  local KIBANA="${KIBANA_URL}"
  local AUTH="Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}"
  local COUNT=0

  for ROLE_FILE in "${RBAC_DIR}"/*.json; do
    [[ -f "${ROLE_FILE}" ]] || continue
    local ROLE_NAME
    ROLE_NAME=$(basename "${ROLE_FILE}" .json)

    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /tmp/role_resp.json -w "%{http_code}" -X PUT \
      "${KIBANA}/api/security/role/${ROLE_NAME}" \
      -H "${AUTH}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
      -d @"${ROLE_FILE}")

    if [[ "${HTTP_CODE}" =~ ^2 ]]; then
      echo "  ✓ role: ${ROLE_NAME}"
      COUNT=$((COUNT + 1))
    else
      echo "  ✗ role: ${ROLE_NAME} (HTTP ${HTTP_CODE})"
      python3 -m json.tool < /tmp/role_resp.json 2>/dev/null | head -5
    fi
  done

  [[ "${COUNT}" -eq 0 ]] && echo "  (no roles to provision)"
  rm -f /tmp/role_resp.json
}

# ── Product team project provisioning ────────────────────────────────────────
# Creates a separate Elastic Cloud Serverless project for the checkout product
# team, configures Cross-Project Search (CPS) back to the main platform project,
# and deploys the team dashboards to the product team's own Kibana.

provision_product_team() {
  echo "→ Provisioning product team project"

  # ── 1. Read product team endpoints from Terraform outputs ──
  local PT_PROJECT_ID PT_ES_URL PT_KIBANA_URL
  PT_PROJECT_ID=$(cd "${ROOT_DIR}/infra/elastic" && terraform output -raw product_team_project_id 2>/dev/null || echo "")
  PT_ES_URL=$(cd "${ROOT_DIR}/infra/elastic" && terraform output -raw product_team_elastic_endpoint 2>/dev/null || echo "")
  PT_KIBANA_URL=$(cd "${ROOT_DIR}/infra/elastic" && terraform output -raw product_team_kibana_endpoint 2>/dev/null || echo "")

  if [[ -z "${PT_PROJECT_ID}" ]]; then
    echo "  ✗ product-team project not found — run 'apply' first to create it"
    return 1
  fi

  update_env "PRODUCT_TEAM_PROJECT_ID"  "${PT_PROJECT_ID}"
  update_env "PRODUCT_TEAM_ES_URL"      "${PT_ES_URL}"
  update_env "PRODUCT_TEAM_KIBANA_URL"  "${PT_KIBANA_URL}"
  echo "  ✓ Product team endpoints written to .env"

  # ── 2. Reset product team credentials and mint an API key ──
  echo "→ Resetting product team admin credentials"
  python3 "${MANAGE_PROJECT}" reset-credentials \
    --type observability --id "${PT_PROJECT_ID}" --wait-seconds 30

  eval "$(python3 "${MANAGE_PROJECT}" load-credentials \
    --id "${PT_PROJECT_ID}" --include-admin)"

  # Retry loop — credentials can take longer than 30s to propagate on a fresh project
  echo "→ Creating product team API key (retrying up to 90s)"
  local PT_KEY_JSON PT_KEY_ENCODED PT_ATTEMPT=0
  while [[ ${PT_ATTEMPT} -lt 9 ]]; do
    PT_ATTEMPT=$((PT_ATTEMPT + 1))
    PT_KEY_JSON=$(curl -s -o /tmp/pt_key_resp.json -w "%{http_code}" -X POST \
      "${PT_ES_URL}/_security/api_key" \
      -H "Content-Type: application/json" \
      -u "${ELASTICSEARCH_USERNAME}:${ELASTICSEARCH_PASSWORD}" \
      -d '{"name":"ecomm-otel-product-team"}') || true

    if [[ "${PT_KEY_JSON}" == "200" ]]; then
      PT_KEY_ENCODED=$(python3 -c \
        "import sys,json; print(json.load(open('/tmp/pt_key_resp.json'))['encoded'])" 2>/dev/null) || true
      if [[ -n "${PT_KEY_ENCODED}" ]]; then
        break
      fi
    fi

    echo "  Attempt ${PT_ATTEMPT}/9: got HTTP ${PT_KEY_JSON} — waiting 10s for credential propagation"
    sleep 10
  done
  unset ELASTICSEARCH_USERNAME ELASTICSEARCH_PASSWORD
  rm -f /tmp/pt_key_resp.json

  if [[ -z "${PT_KEY_ENCODED:-}" ]]; then
    echo "✗ Failed to create product team API key after ${PT_ATTEMPT} attempts." >&2
    return 1
  fi

  update_env "PRODUCT_TEAM_API_KEY" "${PT_KEY_ENCODED}"
  echo "  ✓ Product team API key written to .env"

  # ── 3. Configure Cross-Project Search via Elastic Cloud management API ──
  # CPS on Serverless uses PATCH to the origin project (product team),
  # listing the platform project as a linked source.
  echo "→ Configuring Cross-Project Search (product team → platform)"
  local CPS_HTTP CPS_BODY
  CPS_BODY=$(python3 -c "
import json, sys
print(json.dumps({'linked': {'projects': {'${ELASTIC_PROJECT_ID}': {'type': 'observability'}}}}))
")
  CPS_HTTP=$(curl -s -o /tmp/cps_resp.json -w "%{http_code}" -X PATCH \
    "https://api.elastic-cloud.com/api/v1/serverless/projects/observability/${PT_PROJECT_ID}" \
    -H "Authorization: ApiKey ${EC_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${CPS_BODY}")

  if [[ "${CPS_HTTP}" =~ ^2 ]]; then
    echo "  ✓ CPS configured — product team can query platform:traces-*, logs-*, metrics-*"
  else
    echo "  ✗ CPS link failed (HTTP ${CPS_HTTP})"
    python3 -m json.tool < /tmp/cps_resp.json 2>/dev/null | head -8
  fi
  rm -f /tmp/cps_resp.json

  # ── 4. Deploy Checkout Business Overview dashboard via Terraform ──
  # After apply, immediately remove the resource from state so regular
  # tf_apply runs don't attempt to reconcile it without PT credentials.
  echo "→ Deploying product team dashboard via Terraform"
  (
    cd "${ROOT_DIR}/infra/elastic"
    TF_VAR_product_team_kibana_endpoint="${PT_KIBANA_URL}" \
    TF_VAR_product_team_es_endpoint="${PT_ES_URL}" \
    TF_VAR_product_team_api_key="${PT_KEY_ENCODED}" \
    TF_VAR_ec_api_key="${EC_API_KEY}" \
    TF_VAR_elastic_endpoint="${ELASTICSEARCH_URL}" \
    TF_VAR_kibana_endpoint="${KIBANA_URL}" \
    terraform apply -auto-approve \
      -target=elasticstack_kibana_dashboard.product_team_overview[0]
    terraform state rm elasticstack_kibana_dashboard.product_team_overview[0] 2>/dev/null || true
  )
  echo "  ✓ Checkout Business Overview deployed to product team Kibana"
  echo "    ${PT_KIBANA_URL}/app/dashboards"

  echo "✓ Product team project ready"
  echo "  Platform Kibana:     ${KIBANA_URL}"
  echo "  Product team Kibana: ${PT_KIBANA_URL}"
  echo "  CPS alias: FROM platform:traces-generic.otel-default | ..."
}

# ── Team layer provisioning (legacy — main Kibana space) ─────────────────────
# Kept for backward compatibility. New deployments use provision_product_team.

provision_team() {
  local TEAM="${1:-checkout}"
  local SPACE_ID="${2:-product-team}"
  echo "→ Provisioning team layer: ${TEAM} → space: ${SPACE_ID}"

  local DASH_DIR="${ROOT_DIR}/teams/${TEAM}/dashboards"
  local KIBANA="${KIBANA_URL}"
  local AUTH="Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}"
  local COUNT=0

  for DASH_FILE in "${DASH_DIR}"/*.ndjson; do
    [[ -f "${DASH_FILE}" ]] || continue
    local DASH_NAME
    DASH_NAME=$(basename "${DASH_FILE}" .ndjson)

    local HTTP_CODE SUCCESS ERRORS
    HTTP_CODE=$(curl -s -o /tmp/dash_resp.json -w "%{http_code}" -X POST \
      "${KIBANA}/s/${SPACE_ID}/api/saved_objects/_import?overwrite=true" \
      -H "${AUTH}" -H "kbn-xsrf: true" \
      -F "file=@${DASH_FILE};type=application/ndjson")

    SUCCESS=$(python3 -c "import json; print(json.load(open('/tmp/dash_resp.json')).get('successCount', 0))" 2>/dev/null || echo 0)
    ERRORS=$(python3 -c "import json; print(len(json.load(open('/tmp/dash_resp.json')).get('errors', [])))" 2>/dev/null || echo "?")

    if [[ "${HTTP_CODE}" =~ ^2 && "${ERRORS}" == "0" ]]; then
      echo "  ✓ ${DASH_NAME} (${SUCCESS} object(s))"
      COUNT=$((COUNT + 1))
    else
      echo "  ✗ ${DASH_NAME} (HTTP ${HTTP_CODE}, ${ERRORS} error(s))"
      python3 -m json.tool < /tmp/dash_resp.json 2>/dev/null | head -8
    fi
  done

  for PY_FILE in "${DASH_DIR}"/*.py; do
    [[ -f "${PY_FILE}" ]] || continue
    PY_NAME=$(basename "${PY_FILE}" .py)
    if KIBANA_URL="${KIBANA_URL}" ELASTIC_INGEST_API_KEY="${ELASTIC_INGEST_API_KEY}" \
        python3 "${PY_FILE}" 2>&1; then
      COUNT=$((COUNT + 1))
    else
      echo "  ✗ ${PY_NAME} failed"
    fi
  done

  [[ "${COUNT}" -eq 0 ]] && echo "  (no dashboards to provision)"
  rm -f /tmp/dash_resp.json
  echo "  View at: ${KIBANA_URL}/s/${SPACE_ID}/app/dashboards"
}

# ── Slack connector provisioning ─────────────────────────────────────────────
provision_slack_connector() {
  local KIBANA="${KIBANA_URL}"
  local AUTH="Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}"

  if [[ -z "${SLACK_TOKEN:-}" ]] || [[ -z "${SLACK_CHANNEL_ID:-}" ]]; then
    echo "  – Slack vars not set in .env — skipping connector"
    return 0
  fi

  # Check if connector already exists
  local EXISTING_ID
  EXISTING_ID=$(curl -sf "${KIBANA}/api/actions/connectors" -H "${AUTH}" 2>/dev/null | python3 -c "
import json, sys
cs = json.load(sys.stdin)
match = next((c for c in cs if c.get('connector_type_id') == '.slack_api' and 'ecomm-otel' in c.get('name','')), None)
print(match['id'] if match else '')
" 2>/dev/null || echo "")

  if [[ -n "${EXISTING_ID}" ]]; then
    echo "  – Slack connector already exists (${EXISTING_ID})"
    return 0
  fi

  local CHANNEL_NAME="${SLACK_CHANNEL_NAME:-#ecomm-alerts}"
  local HTTP_CODE
  HTTP_CODE=$(curl -s -o /tmp/slack_connector_resp.json -w "%{http_code}" \
    -X POST "${KIBANA}/api/actions/connector" \
    -H "${AUTH}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
    -d "{
      \"name\": \"Slack — ecomm-otel demo\",
      \"connector_type_id\": \".slack_api\",
      \"config\": {\"allowedChannels\": [{\"id\": \"${SLACK_CHANNEL_ID}\", \"name\": \"${CHANNEL_NAME}\"}]},
      \"secrets\": {\"token\": \"${SLACK_TOKEN}\"}
    }")

  if [[ "${HTTP_CODE}" =~ ^2 ]]; then
    local CONNECTOR_ID
    CONNECTOR_ID=$(python3 -c "import json; print(json.load(open('/tmp/slack_connector_resp.json'))['id'])" 2>/dev/null)
    echo "  ✓ Slack connector created (${CONNECTOR_ID})"
  else
    echo "  ✗ Failed to create Slack connector (HTTP ${HTTP_CODE}): $(cat /tmp/slack_connector_resp.json 2>/dev/null)" >&2
    rm -f /tmp/slack_connector_resp.json
    return 1
  fi
  rm -f /tmp/slack_connector_resp.json
}

# ── SLO provisioning ─────────────────────────────────────────────────────────
provision_slos() {
  echo "→ Provisioning SLOs"
  local SLOS_DIR="${ROOT_DIR}/platform/slos"
  local KIBANA="${KIBANA_URL}"
  local AUTH="Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}"

  for SLO_FILE in "${SLOS_DIR}"/*.json; do
    local SLO_NAME
    SLO_NAME=$(python3 -c "import json; print(json.load(open('${SLO_FILE}'))['name'])" 2>/dev/null)

    # Check if SLO with this name already exists
    local EXISTING_SLO_ID
    EXISTING_SLO_ID=$(curl -sf "${KIBANA}/api/observability/slos?size=100" \
      -H "${AUTH}" -H "kbn-xsrf: true" 2>/dev/null | \
      python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('results', []):
    if r.get('name') == '${SLO_NAME}':
        print(r['id']); break
" 2>/dev/null || echo "")

    local HTTP_CODE SLO_ID
    if [[ -n "${EXISTING_SLO_ID}" ]]; then
      echo "  Updating: ${SLO_NAME} (${EXISTING_SLO_ID})"
      HTTP_CODE=$(curl -s -o /tmp/slo_resp.json -w "%{http_code}" -X PUT \
        "${KIBANA}/api/observability/slos/${EXISTING_SLO_ID}" \
        -H "${AUTH}" \
        -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        -d @"${SLO_FILE}")
    else
      echo "  Creating: ${SLO_NAME}"
      HTTP_CODE=$(curl -s -o /tmp/slo_resp.json -w "%{http_code}" -X POST \
        "${KIBANA}/api/observability/slos" \
        -H "${AUTH}" \
        -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        -d @"${SLO_FILE}")
    fi

    if [[ "${HTTP_CODE}" =~ ^2 ]]; then
      SLO_ID=$(python3 -c "import json; d=json.load(open('/tmp/slo_resp.json')); print(d.get('id', '${EXISTING_SLO_ID}'))" 2>/dev/null)
      echo "  ✓ ${SLO_NAME} (id: ${SLO_ID})"
    else
      echo "  ✗ ${SLO_NAME} failed (HTTP ${HTTP_CODE}): $(cat /tmp/slo_resp.json 2>/dev/null)"
    fi
  done

  rm -f /tmp/slo_resp.json
  echo "✓ SLOs provisioned"
}

# ── Alert rule provisioning ───────────────────────────────────────────────────
# Alert definitions live in platform/alerts/*.json.
# Rules are created via /api/alerting/rule and are idempotent by name.
# SLO burn rate rules (slo.rules.burnRate) have a _meta.slo_name field;
# the SLO ID is looked up dynamically so provision_slos must run first.

provision_alerts() {
  echo "→ Provisioning alert rules"
  local KIBANA="${KIBANA_URL}"
  local AUTH="Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}"
  local ALERTS_DIR="${ROOT_DIR}/platform/alerts"

  if [[ ! -d "${ALERTS_DIR}" ]] || [[ -z "$(ls "${ALERTS_DIR}"/*.json 2>/dev/null)" ]]; then
    echo "  No alert definitions found in ${ALERTS_DIR}"
    return
  fi

  # Look up Slack API connector (provisioned by provision_slack_connector) — inject into actions if found
  local SLACK_CONNECTOR_ID=""
  local SLACK_CHANNEL_IDS="[]"
  local _CONNECTORS
  _CONNECTORS=$(curl -sf "${KIBANA}/api/actions/connectors" -H "${AUTH}" 2>/dev/null) || true
  if [[ -n "${_CONNECTORS}" ]]; then
    SLACK_CONNECTOR_ID=$(python3 -c "
import json, sys
for c in json.loads(sys.argv[1]):
    if c.get('connector_type_id') == '.slack_api' and 'ecomm-otel' in c.get('name',''):
        print(c['id']); break
" "${_CONNECTORS}" 2>/dev/null || echo "")
    if [[ -n "${SLACK_CONNECTOR_ID}" ]]; then
      SLACK_CHANNEL_IDS=$(python3 -c "
import json, sys
for c in json.loads(sys.argv[1]):
    if c.get('id') == sys.argv[2]:
        print(json.dumps([ch['id'] for ch in c.get('config',{}).get('allowedChannels',[])])); break
" "${_CONNECTORS}" "${SLACK_CONNECTOR_ID}" 2>/dev/null || echo "[]")
      echo "  → Slack connector found (${SLACK_CONNECTOR_ID}) — wiring to alert actions"
    else
      echo "  – No Slack connector found (run 'terraform apply' with TF_VAR_slack_token set to wire alerts)"
    fi
  fi

  for ALERT_FILE in "${ALERTS_DIR}"/*.json; do
    local RULE_NAME RULE_TYPE
    RULE_NAME=$(python3 -c "import json; print(json.load(open('${ALERT_FILE}'))['name'])" 2>/dev/null)
    RULE_TYPE=$(python3 -c "import json; print(json.load(open('${ALERT_FILE}'))['rule_type_id'])" 2>/dev/null)

    # Check if a rule with this name already exists
    local SEARCH_RESP EXISTING_RULE_ID ENCODED_NAME
    ENCODED_NAME=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${RULE_NAME}")
    SEARCH_RESP=$(curl -sf \
      "${KIBANA}/api/alerting/rules/_find?search_fields=name&search=${ENCODED_NAME}" \
      -H "${AUTH}" -H "kbn-xsrf: true" 2>/dev/null) || true
    EXISTING_RULE_ID=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1]) if sys.argv[1] else {}
for r in data.get('data', []):
    if r.get('name') == sys.argv[2]:
        print(r['id']); break
" "${SEARCH_RESP}" "${RULE_NAME}" 2>/dev/null || echo "")

    # Build the POST payload — inject SLO ID for burn rate rules
    local PAYLOAD
    if [[ "${RULE_TYPE}" == "slo.rules.burnRate" ]]; then
      local SLO_NAME SLO_LIST SLO_ID
      SLO_NAME=$(python3 -c "import json; print(json.load(open('${ALERT_FILE}'))['_meta']['slo_name'])" 2>/dev/null)
      SLO_LIST=$(curl -sf "${KIBANA}/api/observability/slos?size=100" -H "${AUTH}" 2>/dev/null) || true
      SLO_ID=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1]) if sys.argv[1] else {}
for r in data.get('results', []):
    if r.get('name') == sys.argv[2]:
        print(r['id']); sys.exit(0)
print('')
" "${SLO_LIST}" "${SLO_NAME}" 2>/dev/null)
      if [[ -z "${SLO_ID}" ]]; then
        echo "  ✗ ${RULE_NAME} — SLO '${SLO_NAME}' not found (run provision-slos first)"
        continue
      fi
      PAYLOAD=$(python3 -c "
import json, sys, uuid
with open(sys.argv[1]) as f:
    rule = json.load(f)
rule.pop('_meta', None)
rule['params']['sloId'] = sys.argv[2]
for w in rule['params'].get('windows', []):
    if 'id' not in w:
        w['id'] = str(uuid.uuid4())
slack_id = sys.argv[3] if len(sys.argv) > 3 else ''
try: channels = json.loads(sys.argv[4]) if len(sys.argv) > 4 else []
except: channels = []
if slack_id and channels:
    def mk(g, t): return {'id': slack_id, 'group': g, 'params': {'channelIds': channels, 'text': t}, 'frequency': {'summary': False, 'notify_when': 'onActionGroupChange', 'throttle': None}}
    rule['actions'] = [mk('slo.burnRate.critical', ':rotating_light: *{{rule.name}}* — critical burn rate'), mk('slo.burnRate.high', ':warning: *{{rule.name}}* — high burn rate'), mk('recovered', ':white_check_mark: *{{rule.name}}* — burn rate recovered')]
print(json.dumps(rule))
" "${ALERT_FILE}" "${SLO_ID}" "${SLACK_CONNECTOR_ID}" "${SLACK_CHANNEL_IDS}")
    else
      PAYLOAD=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    rule = json.load(f)
rule.pop('_meta', None)
slack_id = sys.argv[2] if len(sys.argv) > 2 else ''
try: channels = json.loads(sys.argv[3]) if len(sys.argv) > 3 else []
except: channels = []
if slack_id and channels:
    def mk(g, t): return {'id': slack_id, 'group': g, 'params': {'channelIds': channels, 'text': t}, 'frequency': {'summary': False, 'notify_when': 'onActionGroupChange', 'throttle': None}}
    rule['actions'] = [mk('query matched', ':fire: *{{rule.name}}* fired'), mk('recovered', ':white_check_mark: *{{rule.name}}* resolved')]
print(json.dumps(rule))
" "${ALERT_FILE}" "${SLACK_CONNECTOR_ID}" "${SLACK_CHANNEL_IDS}")
    fi

    local HTTP_CODE RULE_ID
    if [[ -n "${EXISTING_RULE_ID}" ]]; then
      # Rule exists — PUT to update (rewires Slack actions on re-runs)
      echo "  Updating: ${RULE_NAME} (${EXISTING_RULE_ID})"
      # PUT payload must omit rule_type_id and consumer
      local PUT_PAYLOAD
      PUT_PAYLOAD=$(python3 -c "
import json, sys
p = json.loads(sys.argv[1])
p.pop('rule_type_id', None)
p.pop('consumer', None)
print(json.dumps(p))
" "${PAYLOAD}")
      HTTP_CODE=$(curl -s -o /tmp/alert_resp.json -w "%{http_code}" -X PUT \
        "${KIBANA}/api/alerting/rule/${EXISTING_RULE_ID}" \
        -H "${AUTH}" -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        -d "${PUT_PAYLOAD}")
    else
      echo "  Creating: ${RULE_NAME}"
      HTTP_CODE=$(curl -s -o /tmp/alert_resp.json -w "%{http_code}" -X POST \
        "${KIBANA}/api/alerting/rule" \
        -H "${AUTH}" -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        -d "${PAYLOAD}")
    fi

    if [[ "${HTTP_CODE}" =~ ^2 ]]; then
      RULE_ID=$(python3 -c "import json; print(json.load(open('/tmp/alert_resp.json')).get('id','?'))" 2>/dev/null)
      echo "  ✓ ${RULE_NAME} (id: ${RULE_ID})"
    else
      echo "  ✗ ${RULE_NAME} failed (HTTP ${HTTP_CODE}): $(cat /tmp/alert_resp.json 2>/dev/null)"
    fi
  done

  rm -f /tmp/alert_resp.json
  echo "✓ Alert rules provisioned"
}

# ── ML anomaly detection job provisioning ────────────────────────────────────
# Jobs are defined in platform/ml-jobs/*.json and deployed to Kibana's ML API.
# Each file contains both the job config and an embedded datafeed_config.
# Jobs are opened and datafeeds started after creation so they begin training
# immediately on the live data stream.

provision_ml_jobs() {
  # Elastic Serverless Observability does not expose the generic ML anomaly
  # detector REST API (/api/ml/anomaly_detectors). Jobs must be created via
  # the Kibana UI: Machine Learning > Anomaly Detection > Create job.
  #
  # Job definitions (with correct field paths for this dataset) are in
  # platform/ml-jobs/ and serve as reference configs for manual setup.
  echo "→ ML anomaly detection jobs"
  echo "  ⚠ Serverless Observability restricts the ML API — jobs must be"
  echo "    created via Kibana UI: Machine Learning > Anomaly Detection."
  echo "  Reference configs: platform/ml-jobs/"
  echo "  Jobs to create:"
  local JOBS_DIR="${ROOT_DIR}/platform/ml-jobs"
  for JOB_FILE in "${JOBS_DIR}"/*.json; do
    local JOB_ID DESC
    JOB_ID=$(basename "${JOB_FILE}" .json)
    DESC=$(python3 -c "
import json; d=json.load(open('${JOB_FILE}'))
det=d['analysis_config']['detectors'][0]
print(det.get('detector_description','?'))
" 2>/dev/null || echo "?")
    echo "    • ${JOB_ID}: ${DESC}"
  done
  echo "  See platform/ml-jobs/*.json for full detector and datafeed config."
}

# ── Local dev commands ────────────────────────────────────────────────────────

tf_init() {
  echo "→ Initialising infra/elastic"
  (cd "${ROOT_DIR}/infra/elastic" && terraform init -reconfigure)
}

tf_plan() {
  echo "→ Plan: infra/elastic"
  (cd "${ROOT_DIR}/infra/elastic" && terraform plan \
    -var="ec_api_key=${EC_API_KEY}")
}

tf_apply() {
  # ── Pass 1: create both Elastic projects ──
  echo "→ Apply: infra/elastic (project creation)"
  (cd "${ROOT_DIR}/infra/elastic" && terraform apply -auto-approve \
    -target=ec_observability_project.main \
    -target=ec_observability_project.product_team \
    -var="ec_api_key=${EC_API_KEY}")

  local ELASTIC_ENDPOINT KIBANA_ENDPOINT INGEST_ENDPOINT PROJECT_ID
  ELASTIC_ENDPOINT=$(cd "${ROOT_DIR}/infra/elastic" && terraform output -raw elastic_endpoint)
  KIBANA_ENDPOINT=$(cd  "${ROOT_DIR}/infra/elastic" && terraform output -raw kibana_endpoint)
  INGEST_ENDPOINT=$(cd  "${ROOT_DIR}/infra/elastic" && terraform output -raw ingest_endpoint)
  PROJECT_ID=$(cd       "${ROOT_DIR}/infra/elastic" && terraform output -raw elastic_project_id)

  update_env "ELASTICSEARCH_URL"       "${ELASTIC_ENDPOINT}"
  update_env "KIBANA_URL"              "${KIBANA_ENDPOINT}"
  update_env "ELASTIC_INGEST_ENDPOINT" "${INGEST_ENDPOINT}"
  update_env "ELASTIC_PROJECT_ID"      "${PROJECT_ID}"

  echo "  Elasticsearch: ${ELASTIC_ENDPOINT}"
  echo "  Kibana:        ${KIBANA_ENDPOINT}"
  echo "  Ingest (mOTLP): ${INGEST_ENDPOINT}"

  # ── Provision ingest API key (before pass 2 — Kibana resources need project key) ──
  provision_ingest_key "${PROJECT_ID}"

  # Reload .env so ELASTIC_INGEST_API_KEY is in scope for pass 2
  set -a; source "${ROOT_DIR}/.env"; set +a

  # ── Pass 2: full elastic apply (Kibana resources) ──
  # Uses ELASTIC_INGEST_API_KEY for Kibana auth — EC cloud key is rejected by Serverless Kibana.
  echo "→ Apply: infra/elastic (full)"
  (cd "${ROOT_DIR}/infra/elastic" && terraform apply -auto-approve \
    -var="ec_api_key=${EC_API_KEY}" \
    -var="elastic_endpoint=${ELASTIC_ENDPOINT}" \
    -var="kibana_endpoint=${KIBANA_ENDPOINT}" \
    -var="kibana_api_key=${ELASTIC_INGEST_API_KEY}" \
    -var="product_team_kibana_endpoint=" \
    -var="product_team_es_endpoint=" \
    -var="product_team_api_key=")

  # ── Provision Elasticsearch resources ──
  provision_pipelines

  # ── Provision Kibana spaces and RBAC for platform space (no product-team space — it has its own project) ──
  provision_spaces
  provision_rbac

  # ── Pre-flight: verify required vars before starting containers ──
  echo "→ Pre-flight check..."
  local MISSING=0
  for KEY in ELASTIC_INGEST_ENDPOINT ELASTIC_INGEST_API_KEY; do
    local VAL
    VAL=$(grep "^${KEY}=" "${ROOT_DIR}/.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
    if [[ -z "${VAL}" ]]; then
      echo "  ✗ ${KEY} is missing from .env"
      MISSING=1
    else
      echo "  ✓ ${KEY}"
    fi
  done
  if [[ "${MISSING}" -eq 1 ]]; then
    echo "Aborting: fix missing vars above before starting containers."
    return 1
  fi

  # ── Start local Docker stack ──
  echo "→ Starting local services"
  (cd "${ROOT_DIR}" && docker compose up -d)
  echo "→ Starting load generator"
  (cd "${ROOT_DIR}" && docker compose --profile load up -d load-generator)
  echo "→ Starting browser simulator (Playwright RUM)"
  (cd "${ROOT_DIR}" && docker compose --profile rum up -d browser-simulator)
  echo "→ Starting mobile simulator (Playwright device emulation)"
  (cd "${ROOT_DIR}" && docker compose --profile rum up -d mobile-simulator)

  # Wait for first traces to land before creating SLOs and ML jobs
  echo "→ Waiting 30s for initial traces to land..."
  sleep 30

  # ── Provision Slack connector (must exist before alerts) ──
  provision_slack_connector

  # ── Provision SLOs ──
  provision_slos

  # ── Provision alert rules (depends on SLO IDs + Slack connector from above) ──
  provision_alerts

  # ── Print ML job instructions ──
  provision_ml_jobs

  # ── Provision product team project + CPS ──
  provision_product_team

  echo ""
  echo "✓ Demo stack ready"
  echo "  Platform Kibana:     ${KIBANA_URL}"
  echo "  Product Team Kibana: ${PRODUCT_TEAM_KIBANA_URL:-not yet provisioned}"
  echo ""
  echo "  Run ./scripts/demo.sh test to verify the pipeline."
}

_destroy_elastic() {
  echo "→ Stopping local Docker stack"
  (cd "${ROOT_DIR}" && docker compose --profile load --profile rum down)

  echo "→ Destroying Elastic Cloud project"
  # Drop the product team dashboard from state before destroy — the provider
  # alias needs live PT credentials to destroy it, but the EC project deletion
  # cascades and removes all Kibana resources anyway.
  (cd "${ROOT_DIR}/infra/elastic" && \
    terraform state rm elasticstack_kibana_dashboard.product_team_overview[0] 2>/dev/null || true)
  (cd "${ROOT_DIR}/infra/elastic" && terraform destroy -auto-approve \
    -var="ec_api_key=${EC_API_KEY}")

  for KEY in ELASTICSEARCH_URL KIBANA_URL ELASTIC_INGEST_ENDPOINT ELASTIC_INGEST_API_KEY ELASTIC_PROJECT_ID \
             PRODUCT_TEAM_PROJECT_ID PRODUCT_TEAM_ES_URL PRODUCT_TEAM_KIBANA_URL PRODUCT_TEAM_API_KEY PRODUCT_TEAM_CPS_API_KEY; do
    sed -i.bak "/^${KEY}=/d" "${ROOT_DIR}/.env" && rm -f "${ROOT_DIR}/.env.bak"
  done

  echo "✓ Elastic project destroyed."
}

tf_destroy() {
  echo "WARNING: This will stop the local Docker stack and destroy the Elastic Cloud project."
  read -rp "Type 'destroy' to confirm: " confirm
  [[ "${confirm}" == "destroy" ]] || { echo "Aborted."; exit 1; }
  _destroy_elastic
  echo "  Re-run './scripts/demo.sh apply' to recreate."
}

# ── AWS / Universal Profiling host ───────────────────────────────────────────

provision_fleet_policy() {
  local KIBANA="${KIBANA_URL}"
  local AUTH="Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}"
  local POLICY_NAME="ecomm-otel — Universal Profiling Host"
  local SYS_VERSION="${SYSTEM_INTEGRATION_VERSION:-1.62.0}"

  echo "→ Provisioning Fleet agent policy"

  # Always fetch the Fleet server URL from Kibana — the .env value can go stale
  local FLEET_SERVER_URL
  FLEET_SERVER_URL=$(curl -sf \
    "${KIBANA}/api/fleet/fleet_server_hosts" \
    -H "${AUTH}" 2>/dev/null | python3 -c "
import json, sys
items = json.load(sys.stdin).get('items', [])
default = next((i for i in items if i.get('is_default') and not i.get('is_internal')), None)
print(default['host_urls'][0] if default and default.get('host_urls') else '')
" 2>/dev/null || echo "")

  if [[ -n "${FLEET_SERVER_URL}" ]]; then
    update_env "FLEET_URL" "${FLEET_SERVER_URL}"
    FLEET_URL="${FLEET_SERVER_URL}"
    echo "  ✓ Fleet URL: ${FLEET_URL}"
  else
    echo "  ✗ Could not fetch Fleet server URL from Kibana" >&2
    return 1
  fi

  # Check if policy already exists (list all, filter in Python — avoids em-dash kuery encoding issues)
  local POLICY_ID
  POLICY_ID=$(curl -sf \
    "${KIBANA}/api/fleet/agent_policies?perPage=100" \
    -H "${AUTH}" 2>/dev/null | python3 -c "
import json, sys
name = sys.argv[1]
items = json.load(sys.stdin).get('items', [])
match = next((i for i in items if i.get('name') == name), None)
print(match['id'] if match else '')
" "${POLICY_NAME}" 2>/dev/null || echo "")

  if [[ -n "${POLICY_ID}" ]]; then
    echo "  – policy already exists (${POLICY_ID})"
  else
    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /tmp/fleet_policy_resp.json -w "%{http_code}" \
      -X POST "${KIBANA}/api/fleet/agent_policies" \
      -H "${AUTH}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
      -d "{\"name\":\"${POLICY_NAME}\",\"namespace\":\"default\",\"description\":\"EC2 demo host: system metrics + logs. Enable Universal Profiling integration via Kibana UI.\"}")
    if [[ "${HTTP_CODE}" =~ ^2 ]]; then
      POLICY_ID=$(python3 -c "import json; print(json.load(open('/tmp/fleet_policy_resp.json'))['item']['id'])" 2>/dev/null)
      echo "  ✓ policy created (${POLICY_ID})"
    elif [[ "${HTTP_CODE}" == "409" ]]; then
      # Already exists — extract ID from error message
      POLICY_ID=$(python3 -c "
import json, re
msg = json.load(open('/tmp/fleet_policy_resp.json')).get('message', '')
m = re.search(r\"'([0-9a-f-]{36})'\", msg)
print(m.group(1) if m else '')
" 2>/dev/null)
      if [[ -n "${POLICY_ID}" ]]; then
        echo "  – policy already exists (${POLICY_ID})"
      else
        echo "  ✗ policy conflict but could not extract ID" >&2
        cat /tmp/fleet_policy_resp.json >&2; rm -f /tmp/fleet_policy_resp.json; return 1
      fi
    else
      echo "  ✗ failed to create policy (HTTP ${HTTP_CODE}): $(cat /tmp/fleet_policy_resp.json 2>/dev/null)" >&2
      rm -f /tmp/fleet_policy_resp.json; return 1
    fi
  fi

  # Attach system integration (idempotent check by name + policy)
  local SYS_EXISTING
  SYS_EXISTING=$(curl -sf \
    "${KIBANA}/api/fleet/package_policies?kuery=name:\"system-profiling-host\"" \
    -H "${AUTH}" 2>/dev/null | python3 -c "
import json, sys
items = [i for i in json.load(sys.stdin).get('items', []) if i.get('policy_id') == sys.argv[1]]
print(items[0]['id'] if items else '')
" "${POLICY_ID}" 2>/dev/null || echo "")

  if [[ -n "${SYS_EXISTING}" ]]; then
    echo "  – system integration already attached"
  else
    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /tmp/fleet_pkg_resp.json -w "%{http_code}" \
      -X POST "${KIBANA}/api/fleet/package_policies" \
      -H "${AUTH}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
      -d "{\"name\":\"system-profiling-host\",\"namespace\":\"default\",\"policy_id\":\"${POLICY_ID}\",\"package\":{\"name\":\"system\",\"version\":\"${SYS_VERSION}\"},\"inputs\":{}}")
    if [[ "${HTTP_CODE}" =~ ^2 ]]; then
      echo "  ✓ system integration attached (v${SYS_VERSION})"
    elif [[ "${HTTP_CODE}" == "409" ]]; then
      echo "  – system integration already attached"
    else
      echo "  ✗ failed to attach system integration (HTTP ${HTTP_CODE}): $(cat /tmp/fleet_pkg_resp.json 2>/dev/null)" >&2
      echo "  Hint: set SYSTEM_INTEGRATION_VERSION in .env (check Fleet > Integrations > System for the right version)" >&2
      rm -f /tmp/fleet_pkg_resp.json; return 1
    fi
  fi

  # Fetch enrollment token
  local TOKEN
  TOKEN=$(curl -sf \
    "${KIBANA}/api/fleet/enrollment_api_keys?kuery=policy_id:\"${POLICY_ID}\"" \
    -H "${AUTH}" 2>/dev/null | python3 -c "
import json, sys
items = json.load(sys.stdin).get('items', [])
print(items[0]['api_key'] if items else '')
" 2>/dev/null || echo "")

  if [[ -n "${TOKEN}" ]]; then
    update_env "FLEET_ENROLLMENT_TOKEN" "${TOKEN}"
    echo "  ✓ enrollment token saved to .env"
  else
    echo "  ✗ could not retrieve enrollment token" >&2
    return 1
  fi

  rm -f /tmp/fleet_policy_resp.json /tmp/fleet_pkg_resp.json
  echo "✓ Fleet policy ready"
}

tf_apply_aws() {
  echo "→ Apply: infra/aws (Fleet policy + EC2 profiling host)"

  for KEY in ELASTICSEARCH_URL KIBANA_URL FLEET_URL EC_API_KEY ELASTIC_INGEST_API_KEY; do
    local VAL
    VAL=$(grep "^${KEY}=\|^export ${KEY}=" "${ROOT_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    if [[ -z "${VAL}" ]]; then
      echo "  ✗ ${KEY} not set in .env — run './scripts/demo.sh apply' first" >&2
      return 1
    fi
  done

  # Create Fleet policy and enrollment token via Kibana API
  provision_fleet_policy

  # Reload .env to pick up FLEET_ENROLLMENT_TOKEN
  set -a; source "${ROOT_DIR}/.env"; set +a

  (cd "${ROOT_DIR}/infra/aws" && terraform init -reconfigure)

  # Required SA tagging vars — fail fast if not set
  for TAG_KEY in TEAM PROJECT; do
    local TAG_VAL
    TAG_VAL=$(grep "^${TAG_KEY}=" "${ROOT_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    if [[ -z "${TAG_VAL}" ]]; then
      echo "  ✗ ${TAG_KEY} not set in .env — required for AWS resource tagging (Elastic SA policy)" >&2
      echo "    Set TEAM (e.g. emea_central_entr) and PROJECT (e.g. timothybrophy) in .env" >&2
      return 1
    fi
  done

  # shellcheck disable=SC2046
  (cd "${ROOT_DIR}/infra/aws" && terraform apply -auto-approve \
    -var="fleet_url=${FLEET_URL}" \
    -var="fleet_enrollment_token=${FLEET_ENROLLMENT_TOKEN}" \
    -var="team=${TEAM}" \
    -var="project=${PROJECT}" \
    ${KEEP_UNTIL:+-var="keep_until=${KEEP_UNTIL}"} \
    ${ELASTIC_AGENT_VERSION:+-var="agent_version=${ELASTIC_AGENT_VERSION}"} \
    ${KEY_PAIR_NAME:+-var="key_pair_name=${KEY_PAIR_NAME}"})

  local INSTANCE_ID SSM_CMD
  INSTANCE_ID=$(cd "${ROOT_DIR}/infra/aws" && terraform output -raw profiling_host_instance_id 2>/dev/null || echo "pending")
  SSM_CMD=$(cd "${ROOT_DIR}/infra/aws" && terraform output -raw ssm_connect_command 2>/dev/null || echo "")

  echo ""
  echo "✓ Profiling host ready"
  echo "  Instance ID: ${INSTANCE_ID}"
  echo ""
  echo "  Debug (no SSH key needed — wait ~2 min for SSM agent to register):"
  echo "  ${SSM_CMD}"
  echo "  Then: sudo cat /var/log/elastic-agent-install.log"
  echo ""
  echo "  Next: enable Universal Profiling integration in Kibana:"
  echo "  Fleet > Agent Policies > ${POLICY_NAME:-ecomm-otel — Universal Profiling Host} > Add integration"
}

_destroy_aws() {
  # shellcheck disable=SC2046
  (cd "${ROOT_DIR}/infra/aws" && terraform destroy -auto-approve \
    -var="fleet_url=${FLEET_URL:-dummy}" \
    -var="fleet_enrollment_token=${FLEET_ENROLLMENT_TOKEN:-dummy}" \
    -var="team=${TEAM:-field}" \
    -var="project=${PROJECT:-unknown}" \
    ${KEEP_UNTIL:+-var="keep_until=${KEEP_UNTIL}"} \
    ${ELASTIC_AGENT_VERSION:+-var="agent_version=${ELASTIC_AGENT_VERSION}"} \
    ${KEY_PAIR_NAME:+-var="key_pair_name=${KEY_PAIR_NAME}"})

  echo "✓ Profiling host destroyed."
}

tf_destroy_aws() {
  echo "WARNING: This will destroy the EC2 profiling host."
  read -rp "Type 'destroy' to confirm: " confirm
  [[ "${confirm}" == "destroy" ]] || { echo "Aborted."; exit 1; }
  _destroy_aws
}

# ── Master build / teardown ───────────────────────────────────────────────────

build_all() {
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  ecomm-otel — full stack build                       ║"
  echo "║  Elastic Cloud + Docker + AWS profiling host         ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""

  # Step 1: Elastic Cloud + Docker + SLOs + alerts
  tf_apply

  # Step 2: AWS profiling host (depends on FLEET_URL set by step 1)
  echo ""
  echo "→ Phase 2: AWS profiling host"
  tf_apply_aws

  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  ✓ Full stack ready                                  ║"
  echo "║  Run ./scripts/demo.sh test to verify                ║"
  echo "║  Run ./scripts/demo.sh trigger-incident to demo UC1  ║"
  echo "╚══════════════════════════════════════════════════════╝"
}

teardown_all() {
  echo "WARNING: This will destroy ALL resources:"
  echo "  • EC2 profiling host (AWS)"
  echo "  • Elastic Cloud project (Kibana, SLOs, alerts, connectors)"
  echo "  • Local Docker stack"
  echo ""
  read -rp "Type 'teardown' to confirm: " confirm
  [[ "${confirm}" == "teardown" ]] || { echo "Aborted."; exit 1; }

  # Destroy AWS first (needs FLEET_URL + credentials still in .env)
  echo ""
  echo "→ Phase 1: destroying AWS profiling host"
  _destroy_aws || echo "  (AWS destroy failed or no state — continuing)"

  # Destroy Elastic Cloud + Docker
  echo ""
  echo "→ Phase 2: destroying Elastic Cloud project + Docker stack"
  _destroy_elastic

  echo ""
  echo "✓ Full teardown complete."
  echo "  Re-run './scripts/demo.sh build' to recreate from scratch."
}

# ── Demo controls ─────────────────────────────────────────────────────────────

trigger_incident() {
  local FLAG_URL="${FLAG_SERVICE_URL:-http://localhost:8090}"
  echo "→ Triggering incident: realtime_fraud_detection=true"
  echo "  This enables a synchronous fraud check on every checkout:"
  echo "  • checkout-service: +400–900ms latency per request, 8% timeout errors"
  echo "    (more under concurrent load — only 3 FraudShield pool slots, requests queue for one)"
  echo "  • order-service:    +100–300ms backpressure, Kafka producer lag"
  echo "  • notification-service: downstream delay on order confirmations"
  curl -sf -X POST "${FLAG_URL}/flags" \
    -H "Content-Type: application/json" \
    -d '{"name":"realtime_fraud_detection","value":true}' | python3 -m json.tool
  echo ""
  echo "  Run './scripts/demo.sh reset' to restore normal behaviour."
}

reset_demo() {
  local FLAG_URL="${FLAG_SERVICE_URL:-http://localhost:8090}"
  curl -sf -X POST "${FLAG_URL}/flags/reset" | python3 -m json.tool
  echo "✓ Demo reset complete"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${1:-}" in
  build)            build_all ;;
  teardown)         teardown_all ;;
  apply)            tf_apply ;;
  destroy)          tf_destroy ;;
  apply-aws)        tf_apply_aws ;;
  destroy-aws)      tf_destroy_aws ;;
  provision-fleet)     provision_fleet_policy ;;
  provision-connector) provision_slack_connector ;;
  init)             tf_init ;;
  plan)             tf_plan ;;
  trigger-incident) trigger_incident ;;
  reset)            reset_demo ;;
  provision-ml)      provision_ml_jobs ;;
  provision-alerts)  provision_alerts ;;
  provision-slos)            provision_slos ;;
  provision-spaces)          provision_spaces ;;
  provision-rbac)            provision_rbac ;;
  provision-product-team)    provision_product_team ;;
  provision-team)            provision_team "checkout" "product-team" ;;
  refresh-key)
    PROJECT_ID="${ELASTIC_PROJECT_ID:-}"
    if [[ -z "${PROJECT_ID}" ]]; then
      echo "Error: ELASTIC_PROJECT_ID not set in .env" >&2; exit 1
    fi
    provision_ingest_key "${PROJECT_ID}"
    echo "→ Recreating collector to pick up new key"
    (cd "${ROOT_DIR}" && docker compose up -d --force-recreate collector)
    echo "✓ Done"
    ;;
  test) bash "${SCRIPT_DIR}/test.sh" ;;
  *) usage; exit 1 ;;
esac
