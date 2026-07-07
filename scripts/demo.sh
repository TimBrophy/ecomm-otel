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
  apply-aws           Create Fleet policy + EC2 profiling host enrolled to Serverless Fleet
  apply-profiling-host  Destroy + rebuild EC2 host enrolled to stateful ESS Fleet (Universal Profiling)
  deploy-profiling-stress  Install + start checkout stress workload on EC2 profiling host
  destroy-aws         Destroy EC2 profiling host
  provision-profiling-deployment  Spin up stateful ESS deployment for Universal Profiling (run once)
  init                terraform init for infra/elastic
  plan                terraform plan for infra/elastic
  provision-fleet      (Re-)create Fleet agent policy + system integration only
  provision-connector  (Re-)create Slack API connector in Kibana
  refresh-key         Mint a fresh ingest API key and restart the collector
  provision-slos      (Re-)deploy SLOs to Kibana
  provision-knowledge-base  (Re-)index runbook/playbook docs into sre-runbooks
  provision-agent-builder   (Re-)deploy Agent Builder tools + autonomous-SRE agent
  provision-workflows       (Re-)deploy incident-response workflows from platform/workflows/
  provision-alerts    (Re-)deploy Kibana alert rules from platform/alerts/
  provision-ingest-pipelines  (Re-)deploy ES ingest pipelines from platform/ingest-pipelines/ and set as default_pipeline on traces index
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
  echo "  CPS query: FROM traces-generic.otel-default | ...  (no prefix — merges transparently via Kibana)"
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

  # alerts layer — Python scripts in teams/${TEAM}/alerts/
  local ALERT_DIR="${ROOT_DIR}/teams/${TEAM}/alerts"
  if [[ -d "${ALERT_DIR}" ]]; then
    for PY_FILE in "${ALERT_DIR}"/*.py; do
      [[ -f "${PY_FILE}" ]] || continue
      PY_NAME=$(basename "${PY_FILE}" .py)
      if KIBANA_URL="${KIBANA_URL}" ELASTIC_INGEST_API_KEY="${ELASTIC_INGEST_API_KEY}" \
          python3 "${PY_FILE}" 2>&1; then
        COUNT=$((COUNT + 1))
      else
        echo "  ✗ ${PY_NAME} (alert provisioning failed)"
      fi
    done
  fi

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

# ── Knowledge base provisioning ────────────────────────────────────────────────
# Runbook/playbook docs live in platform/runbooks/*.json. Indexed into
# sre-runbooks with a semantic_text `content` field (default ELSER inference
# endpoint — no separate inference-endpoint setup needed on this cluster).
# Doc _id = filename basename, so re-runs overwrite in place (idempotent).

provision_knowledge_base() {
  echo "→ Provisioning knowledge base"
  local KB_DIR="${ROOT_DIR}/platform/runbooks"
  local INDEX="sre-runbooks"
  local AUTH="Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}"

  if [[ ! -d "${KB_DIR}" ]] || [[ -z "$(ls "${KB_DIR}"/*.json 2>/dev/null)" ]]; then
    echo "  (no runbook docs found in ${KB_DIR})"
    return 0
  fi

  # Create the index. 400 (resource_already_exists_exception) is success —
  # matches the idempotent-PUT spirit used elsewhere in this file. Note: this
  # only creates the index; changing the mapping on an existing index requires
  # a separate _mapping PUT (new fields) or delete+recreate (changed field type).
  local CREATE_CODE
  CREATE_CODE=$(curl -s -o /tmp/kb_idx.json -w "%{http_code}" -X PUT \
    "${ELASTICSEARCH_URL}/${INDEX}" \
    -H "${AUTH}" -H "Content-Type: application/json" \
    -d '{
      "mappings": {
        "properties": {
          "title": {"type": "keyword"},
          "service": {"type": "keyword"},
          "applies_when": {"type": "text"},
          "content": {"type": "semantic_text"}
        }
      }
    }')
  if [[ "${CREATE_CODE}" == "200" ]]; then
    echo "  ✓ index ${INDEX} created"
  elif [[ "${CREATE_CODE}" == "400" ]]; then
    echo "  – index ${INDEX} already exists"
  else
    echo "  ✗ index create failed (HTTP ${CREATE_CODE}): $(cat /tmp/kb_idx.json 2>/dev/null)"
    rm -f /tmp/kb_idx.json
    return 1
  fi

  # Bulk-index every doc, fixed _id = filename basename.
  : > /tmp/kb_bulk.ndjson
  local COUNT=0
  for DOC in "${KB_DIR}"/*.json; do
    [[ -f "${DOC}" ]] || continue
    local DOC_ID; DOC_ID=$(basename "${DOC}" .json)
    printf '{"index":{"_index":"%s","_id":"%s"}}\n' "${INDEX}" "${DOC_ID}" >> /tmp/kb_bulk.ndjson
    python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))" "${DOC}" >> /tmp/kb_bulk.ndjson
    COUNT=$((COUNT + 1))
  done

  local BULK_CODE
  BULK_CODE=$(curl -s -o /tmp/kb_bulk_resp.json -w "%{http_code}" -X POST \
    "${ELASTICSEARCH_URL}/_bulk?refresh=wait_for" \
    -H "${AUTH}" -H "Content-Type: application/x-ndjson" \
    --data-binary @/tmp/kb_bulk.ndjson)
  local ERRORS
  ERRORS=$(python3 -c "import json; print(json.load(open('/tmp/kb_bulk_resp.json')).get('errors', True))" 2>/dev/null || echo "True")
  if [[ "${BULK_CODE}" =~ ^2 && "${ERRORS}" == "False" ]]; then
    echo "  ✓ indexed ${COUNT} runbook doc(s)"
  else
    echo "  ✗ bulk index failed (HTTP ${BULK_CODE}): $(head -c 400 /tmp/kb_bulk_resp.json 2>/dev/null)"
  fi

  rm -f /tmp/kb_idx.json /tmp/kb_bulk.ndjson /tmp/kb_bulk_resp.json
  echo "✓ Knowledge base provisioned"
}

# ── Agent Builder provisioning ──────────────────────────────────────────────────
# Custom tools live in platform/agent-tools/*.json, the agent in
# platform/agents/*.json. Tools are provisioned first since the agent
# references their ids. Idempotent via POST (create); on 400/409 (already
# exists) falls back to PUT /{id} (update).

provision_agent_builder() {
  echo "→ Provisioning Agent Builder"
  local KIBANA="${KIBANA_URL}"
  local AUTH="Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}"

  _ab_upsert() {
    local KIND="$1" FILE="$2" RID
    RID=$(python3 -c "import json; print(json.load(open('${FILE}'))['id'])" 2>/dev/null)
    local CODE
    CODE=$(curl -s -o /tmp/ab_resp.json -w "%{http_code}" -X POST \
      "${KIBANA}/api/agent_builder/${KIND}" \
      -H "${AUTH}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
      -d @"${FILE}")
    if [[ "${CODE}" == "409" || "${CODE}" == "400" ]]; then
      # PUT (update) rejects 'id' and 'type' in the body — both are immutable,
      # implied by the URL — so strip them before re-sending.
      local UPDATE_PAYLOAD
      UPDATE_PAYLOAD=$(python3 -c "
import json
d = json.load(open('${FILE}'))
d.pop('id', None); d.pop('type', None)
print(json.dumps(d))
")
      CODE=$(curl -s -o /tmp/ab_resp.json -w "%{http_code}" -X PUT \
        "${KIBANA}/api/agent_builder/${KIND}/${RID}" \
        -H "${AUTH}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
        -d "${UPDATE_PAYLOAD}")
      if [[ "${CODE}" =~ ^2 ]]; then
        echo "  ↻ ${KIND%s}: ${RID} (updated)"
      else
        echo "  ✗ ${KIND%s}: ${RID} (HTTP ${CODE}): $(head -c 300 /tmp/ab_resp.json 2>/dev/null)"
      fi
    elif [[ "${CODE}" =~ ^2 ]]; then
      echo "  ✓ ${KIND%s}: ${RID} (created)"
    else
      echo "  ✗ ${KIND%s}: ${RID} (HTTP ${CODE}): $(head -c 300 /tmp/ab_resp.json 2>/dev/null)"
    fi
  }

  local TOOLS_DIR="${ROOT_DIR}/platform/agent-tools"
  local AGENTS_DIR="${ROOT_DIR}/platform/agents"
  if [[ -d "${TOOLS_DIR}" ]]; then
    for T in "${TOOLS_DIR}"/*.json; do [[ -f "${T}" ]] && _ab_upsert tools "${T}"; done
  fi
  if [[ -d "${AGENTS_DIR}" ]]; then
    for A in "${AGENTS_DIR}"/*.json; do [[ -f "${A}" ]] && _ab_upsert agents "${A}"; done
  fi

  rm -f /tmp/ab_resp.json
  echo "✓ Agent Builder provisioned"
}

# ── Workflow provisioning ───────────────────────────────────────────────────────
# Workflow definitions live in platform/workflows/*.yaml.
# POST /api/workflows takes a bulk {"workflows":[{"yaml": "..."}]} envelope,
# but is NOT idempotent by name — re-POSTing (even with ?overwrite=true, which
# does something else entirely) creates a duplicate workflow every time.
# So provisioning here follows the same find-then-POST/PUT pattern as SLOs:
# look up an existing workflow by name, PUT /api/workflows/workflow/{id} to
# update it if found, POST (bulk, single-item) to create it otherwise.

provision_workflows() {
  echo "→ Provisioning workflows"
  local KIBANA="${KIBANA_URL}"
  local AUTH="Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}"
  local WF_DIR="${ROOT_DIR}/platform/workflows"

  if [[ ! -d "${WF_DIR}" ]] || [[ -z "$(ls "${WF_DIR}"/*.yaml 2>/dev/null)" ]]; then
    echo "  (no workflow definitions found in ${WF_DIR})"
    return 0
  fi

  for WF_FILE in "${WF_DIR}"/*.yaml; do
    [[ -f "${WF_FILE}" ]] || continue
    local WF_NAME
    WF_NAME=$(grep "^name:" "${WF_FILE}" | head -1 | sed 's/^name:[[:space:]]*//')

    local EXISTING_WF_ID
    EXISTING_WF_ID=$(curl -sf "${KIBANA}/api/workflows?query=${WF_NAME}" \
      -H "${AUTH}" -H "kbn-xsrf: true" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for w in d.get('results', d.get('data', [])):
    if w.get('name') == '${WF_NAME}':
        print(w['id']); break
" 2>/dev/null || echo "")

    local YAML_PAYLOAD
    YAML_PAYLOAD=$(python3 -c "import json; print(json.dumps(open('${WF_FILE}').read()))")

    local HTTP_CODE
    if [[ -n "${EXISTING_WF_ID}" ]]; then
      echo "  Updating: ${WF_NAME} (${EXISTING_WF_ID})"
      HTTP_CODE=$(curl -s -o /tmp/wf_resp.json -w "%{http_code}" -X PUT \
        "${KIBANA}/api/workflows/workflow/${EXISTING_WF_ID}" \
        -H "${AUTH}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
        -d "{\"yaml\": ${YAML_PAYLOAD}}")
    else
      echo "  Creating: ${WF_NAME}"
      HTTP_CODE=$(curl -s -o /tmp/wf_resp.json -w "%{http_code}" -X POST \
        "${KIBANA}/api/workflows" \
        -H "${AUTH}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
        -d "{\"workflows\": [{\"yaml\": ${YAML_PAYLOAD}}]}")
    fi

    if [[ "${HTTP_CODE}" =~ ^2 ]]; then
      echo "  ✓ ${WF_NAME}"
    else
      echo "  ✗ ${WF_NAME} failed (HTTP ${HTTP_CODE}): $(head -c 300 /tmp/wf_resp.json 2>/dev/null)"
    fi
  done

  rm -f /tmp/wf_resp.json
  echo "✓ Workflows provisioned"
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
    rule['actions'] = [mk('slo.burnRate.alert', ':rotating_light: *{{rule.name}}* — critical burn rate'), mk('slo.burnRate.high', ':warning: *{{rule.name}}* — high burn rate'), mk('recovered', ':white_check_mark: *{{rule.name}}* — burn rate recovered')]
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

  # ── Provision autonomous-SRE knowledge base, Agent Builder tools/agent, workflow ──
  provision_knowledge_base
  provision_agent_builder
  provision_workflows

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

  # ── Remove Cross-Project Search link before destroying the platform project ──
  #
  # The EC API blocks deletion of a project that is still linked as a CPS source.
  # Terraform destroy provisioners are unreliable for this on macOS (head -n -1
  # incompatibility) and the provisioner output is suppressed for sensitive vars.
  # We do it explicitly here with full visibility, before terraform destroy runs.
  local PT_PROJECT_ID
  PT_PROJECT_ID=$(cd "${ROOT_DIR}/infra/elastic" && terraform output -raw product_team_project_id 2>/dev/null || echo "")

  if [[ -n "${PT_PROJECT_ID}" ]]; then
    echo "→ Removing CPS link from product team project ${PT_PROJECT_ID}..."
    local CPS_UNLINK_HTTP CPS_UNLINK_BODY
    CPS_UNLINK_BODY='{"linked":{"projects":{}}}'
    CPS_UNLINK_HTTP=$(curl -s -o /tmp/cps_unlink_resp.json -w "%{http_code}" -X PATCH \
      "https://api.elastic-cloud.com/api/v1/serverless/projects/observability/${PT_PROJECT_ID}" \
      -H "Authorization: ApiKey ${EC_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "${CPS_UNLINK_BODY}")

    if [[ "${CPS_UNLINK_HTTP}" =~ ^2 ]] || [[ "${CPS_UNLINK_HTTP}" == "404" ]]; then
      echo "  ✓ CPS unlink complete (HTTP ${CPS_UNLINK_HTTP})"
    else
      echo "  ✗ CPS unlink failed (HTTP ${CPS_UNLINK_HTTP})"
      cat /tmp/cps_unlink_resp.json 2>/dev/null && echo
      echo "  Continuing teardown — you may need to unlink manually before the platform project can be deleted."
    fi
  else
    echo "  (no product team project found in terraform state — skipping CPS unlink)"
  fi

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

tf_apply_profiling_host() {
  echo "→ Apply: infra/aws — EC2 profiling host enrolled to stateful ESS Fleet"

  # Reload .env so we have the profiling vars that were written by provision-profiling-deployment
  set -a; source "${ROOT_DIR}/.env"; set +a

  for KEY in PROFILING_FLEET_URL PROFILING_FLEET_ENROLLMENT_TOKEN; do
    local VAL
    VAL=$(grep "^${KEY}=" "${ROOT_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    if [[ -z "${VAL}" ]]; then
      echo "  ✗ ${KEY} not set in .env — run './scripts/demo.sh provision-profiling-deployment' first" >&2
      return 1
    fi
  done

  for TAG_KEY in TEAM PROJECT; do
    local TAG_VAL
    TAG_VAL=$(grep "^${TAG_KEY}=" "${ROOT_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    if [[ -z "${TAG_VAL}" ]]; then
      echo "  ✗ ${TAG_KEY} not set in .env" >&2; return 1
    fi
  done

  (cd "${ROOT_DIR}/infra/aws" && terraform init -reconfigure)

  # Destroy existing host first (clean slate for the new enrollment)
  echo "  → Destroying existing EC2 host (if any)..."
  (cd "${ROOT_DIR}/infra/aws" && terraform destroy -auto-approve \
    -var="fleet_url=${PROFILING_FLEET_URL}" \
    -var="fleet_enrollment_token=${PROFILING_FLEET_ENROLLMENT_TOKEN}" \
    -var="team=${TEAM}" \
    -var="project=${PROJECT}" \
    ${KEEP_UNTIL:+-var="keep_until=${KEEP_UNTIL}"} \
    ${ELASTIC_AGENT_VERSION:+-var="agent_version=${ELASTIC_AGENT_VERSION}"} \
    ${KEY_PAIR_NAME:+-var="key_pair_name=${KEY_PAIR_NAME}"} 2>/dev/null || true)

  echo "  → Creating new EC2 host enrolled to stateful ESS Fleet..."
  (cd "${ROOT_DIR}/infra/aws" && terraform apply -auto-approve \
    -var="fleet_url=${PROFILING_FLEET_URL}" \
    -var="fleet_enrollment_token=${PROFILING_FLEET_ENROLLMENT_TOKEN}" \
    -var="team=${TEAM}" \
    -var="project=${PROJECT}" \
    ${KEEP_UNTIL:+-var="keep_until=${KEEP_UNTIL}"} \
    ${ELASTIC_AGENT_VERSION:+-var="agent_version=${ELASTIC_AGENT_VERSION}"} \
    ${KEY_PAIR_NAME:+-var="key_pair_name=${KEY_PAIR_NAME}"})

  local INSTANCE_ID SSM_CMD
  INSTANCE_ID=$(cd "${ROOT_DIR}/infra/aws" && terraform output -raw profiling_host_instance_id 2>/dev/null || echo "pending")
  SSM_CMD=$(cd "${ROOT_DIR}/infra/aws" && terraform output -raw ssm_connect_command 2>/dev/null || echo "")

  echo ""
  echo "✓ Profiling host ready — enrolled to stateful ESS Fleet"
  echo "  Instance ID : ${INSTANCE_ID}"
  echo "  Fleet URL   : ${PROFILING_FLEET_URL}"
  echo "  Kibana      : ${PROFILING_KIBANA_URL:-see .env PROFILING_KIBANA_URL}"
  echo ""
  echo "  Debug access (wait ~2 min for SSM to register):"
  echo "  ${SSM_CMD}"
  echo "  Then: sudo cat /var/log/elastic-agent-install.log"
  echo ""
  echo "  Next: add Universal Profiling integration in Kibana:"
  echo "    Fleet > Agent Policies > ecomm-otel — Universal Profiling Host"
  echo "    > Add integration > search 'Universal Profiling'"
  echo "  Then run: ./scripts/demo.sh deploy-profiling-stress"
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

# Waits for the checkout-latency-spike rule to actually fire (real alert doc
# in .alerts-*), then kicks off the autonomous-SRE workflow with an `inputs`
# payload shaped exactly like the native alert-trigger event
# (event.alerts[0]._id/_index, event.rule.id/name) — see the note at the top
# of platform/workflows/autonomous-sre-rca.yaml for why this exists instead of
# the rule's own "Run Workflow" action. Meant to be run in the background;
# logs to ${ROOT_DIR}/.autonomous-sre.log since stdout is detached.
_run_autonomous_investigation() {
  local KIBANA="${KIBANA_URL}" AUTH="Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}"
  local RULE_NAME="Checkout — Latency Spike (Incident Alert)"
  local TRIGGERED_AT; TRIGGERED_AT=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat())")

  echo "[$(date)] waiting for '${RULE_NAME}' to fire..."

  local RULE_ID
  RULE_ID=$(curl -sf "${KIBANA}/api/alerting/rules/_find?per_page=50" -H "${AUTH}" -H "kbn-xsrf: true" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('data', []):
    if r.get('name') == '${RULE_NAME}':
        print(r['id']); break
" 2>/dev/null || echo "")
  if [[ -z "${RULE_ID}" ]]; then
    echo "[$(date)] ✗ could not find rule '${RULE_NAME}' — aborting"; return 1
  fi

  # Poll for a fresh ACTIVE alert doc from this rule (up to ~4 minutes —
  # the rule runs on a 1m schedule over a 5m window).
  local ALERT_ID="" ALERT_INDEX="" ATTEMPT=0
  while [[ ${ATTEMPT} -lt 16 ]]; do
    ATTEMPT=$((ATTEMPT + 1))
    sleep 15
    local HIT
    HIT=$(curl -sf -X POST "${ELASTICSEARCH_URL}/.alerts-*/_search" -H "${AUTH}" -H "Content-Type: application/json" -d "{
      \"size\": 1,
      \"sort\": [{\"@timestamp\": \"desc\"}],
      \"query\": {\"bool\": {\"filter\": [
        {\"term\": {\"kibana.alert.rule.uuid\": \"${RULE_ID}\"}},
        {\"term\": {\"kibana.alert.status\": \"active\"}},
        {\"range\": {\"@timestamp\": {\"gte\": \"${TRIGGERED_AT}\"}}}
      ]}}
    }" 2>/dev/null) || true
    ALERT_ID=$(echo "${HIT}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
hits=d.get('hits',{}).get('hits',[])
print(hits[0]['_id'] if hits else '')" 2>/dev/null || echo "")
    ALERT_INDEX=$(echo "${HIT}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
hits=d.get('hits',{}).get('hits',[])
print(hits[0]['_index'] if hits else '')" 2>/dev/null || echo "")
    if [[ -n "${ALERT_ID}" ]]; then
      echo "[$(date)] ✓ alert fired (${ALERT_ID}) after ~$((ATTEMPT * 15))s"
      break
    fi
    echo "[$(date)] attempt ${ATTEMPT}/16: no active alert yet"
  done
  if [[ -z "${ALERT_ID}" ]]; then
    echo "[$(date)] ✗ rule never fired within ~4 minutes — aborting"; return 1
  fi

  local WORKFLOW_ID
  WORKFLOW_ID=$(curl -sf "${KIBANA}/api/workflows?query=ecomm-otel--autonomous-sre-rca" -H "${AUTH}" -H "kbn-xsrf: true" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for w in d.get('results', d.get('data', [])):
    if w.get('name') == 'ecomm-otel--autonomous-sre-rca':
        print(w['id']); break
" 2>/dev/null || echo "")
  if [[ -z "${WORKFLOW_ID}" ]]; then
    echo "[$(date)] ✗ autonomous-sre-rca workflow not found — run provision-workflows"; return 1
  fi

  local RUN_INPUTS
  RUN_INPUTS=$(python3 -c "
import json
print(json.dumps({'inputs': {
    'alerts': [{'_id': '${ALERT_ID}', '_index': '${ALERT_INDEX}'}],
    'rule': {'id': '${RULE_ID}', 'name': '${RULE_NAME}'},
    'incident_started_at': '${TRIGGERED_AT}'
}}))
")
  local RUN_RESP
  RUN_RESP=$(curl -sf -X POST "${KIBANA}/api/workflows/workflow/${WORKFLOW_ID}/run" \
    -H "${AUTH}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
    -d "${RUN_INPUTS}" 2>/dev/null) || true
  echo "[$(date)] workflow run triggered: ${RUN_RESP}"
}

_ssm_run() {
  # Run a shell command on the profiling EC2 host via SSM.
  # Silently skips if the instance ID isn't available (EC2 not provisioned).
  local CMD="$1"
  local INSTANCE_ID
  INSTANCE_ID=$(cd "${ROOT_DIR}/infra/aws" && terraform output -raw profiling_host_instance_id 2>/dev/null || echo "")
  if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "pending" ]]; then
    return 0
  fi
  aws ssm send-command \
    --region "${AWS_REGION:-eu-central-1}" \
    --instance-ids "${INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"${CMD}\"]" \
    --output text \
    --query "Command.CommandId" > /dev/null 2>&1 || true
}

deploy_profiling_stress() {
  echo "→ Deploying checkout stress workload to profiling host"
  local INSTANCE_ID REGION
  REGION="${AWS_REGION:-eu-central-1}"
  INSTANCE_ID=$(cd "${ROOT_DIR}/infra/aws" && terraform output -raw profiling_host_instance_id 2>/dev/null || echo "")
  if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "pending" ]]; then
    echo "  ✗ EC2 profiling host not provisioned — run 'apply-aws' first"
    return 1
  fi

  # Base64-encode the Java source so it survives SSM JSON quoting
  local JAVA_B64
  JAVA_B64=$(base64 < "${ROOT_DIR}/infra/aws/profiling-stress/CheckoutStress.java" | tr -d '\n')

  # Build a JSON commands array — each element is one shell line
  local PARAMS
  PARAMS=$(python3 -c "
import json
cmds = [
    'set -e',
    'dnf install -y java-21-amazon-corretto-devel 2>/dev/null || true',
    'mkdir -p /opt/checkout-stress',
    'echo ${JAVA_B64} | base64 -d > /opt/checkout-stress/CheckoutStress.java',
    'cd /opt/checkout-stress && javac CheckoutStress.java',
    'pkill -f CheckoutStress 2>/dev/null || true',
    'sleep 1',
    'nohup java -cp /opt/checkout-stress CheckoutStress > /var/log/checkout-stress.log 2>&1 &',
    'echo checkout-stress started',
]
print(json.dumps({'commands': cmds}))
" 2>/dev/null)

  echo "  Uploading via SSM (Java install + compile takes ~60s on first run)..."
  local CMD_ID
  CMD_ID=$(aws ssm send-command \
    --region "${REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" \
    --cli-input-json "{\"DocumentName\":\"AWS-RunShellScript\",\"InstanceIds\":[\"${INSTANCE_ID}\"],\"Parameters\":${PARAMS}}" \
    --output text \
    --query "Command.CommandId" 2>&1 || echo "")

  if [[ -z "${CMD_ID}" ]] || echo "${CMD_ID}" | grep -q "Error\|error"; then
    echo "  ✗ SSM send-command failed:"
    echo "    ${CMD_ID}"
    return 1
  fi

  echo "  SSM command ID: ${CMD_ID}"
  echo "  ✓ Stress workload deploying. Poll status with:"
  echo "    aws ssm get-command-invocation --command-id ${CMD_ID} --instance-id ${INSTANCE_ID} --region ${REGION}"
  echo "  Profiling data appears in Kibana > Observability > Universal Profiling within ~2 min."
  echo "  Normal mode : validateCart / fetchProductPrices / processPayment / createOrder are balanced"
  echo "  Slow mode   : run './scripts/demo.sh trigger-incident' — fraudShieldApiCall dominates"
}

provision_profiling_deployment() {
  # Creates a stateful ESS deployment for Universal Profiling via EC REST API.
  # Terraform ec_deployment is not used — all deployment templates in
  # aws-eu-central-1 reference deprecated ICs that the EC API rejects at plan time.
  echo "→ Provisioning stateful ESS deployment for Universal Profiling"

  local STACK_VER="${PROFILING_STACK_VERSION:-8.17.3}"
  local DEPLOY_NAME="${PROFILING_DEPLOYMENT_NAME:-ecomm-otel-demo-profiling}"
  local REGION="aws-eu-central-1"
  local EC_API="https://api.elastic-cloud.com/api/v1"

  # Idempotent: check if deployment already exists
  local EXISTING_DID
  EXISTING_DID=$(curl -sf "${EC_API}/deployments?q=name:${DEPLOY_NAME}&size=5" \
    -H "Authorization: ApiKey ${EC_API_KEY}" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('deployments', [])
match = next((d for d in items if d.get('name') == '${DEPLOY_NAME}'), None)
print(match['id'] if match else '')
" 2>/dev/null || echo "")

  local PROFILING_DID
  if [[ -n "${EXISTING_DID}" ]]; then
    echo "  – deployment already exists (${EXISTING_DID})"
    PROFILING_DID="${EXISTING_DID}"
  else
    echo "  Creating stateful deployment (stack ${STACK_VER}, ARM c6gd, hot-only)..."

    # Build deployment spec with only hot_content topology — avoids all deprecated ICs
    local DEPLOY_BODY
    DEPLOY_BODY=$(python3 -c "
import json
spec = {
  'name': '${DEPLOY_NAME}',
  'resources': {
    'elasticsearch': [{
      'ref_id': 'main-elasticsearch',
      'region': '${REGION}',
      'plan': {
        'deployment_template': {'id': 'aws-cpu-optimized-arm'},
        'elasticsearch': {},
        'cluster_topology': [{
          'id': 'hot_content',
          'node_roles': ['master','ingest','transform','data_hot','remote_cluster_client','data_content'],
          'zone_count': 1,
          'instance_configuration_id': 'aws.es.datahot.c8gd',
          'size': {'value': 4096, 'resource': 'memory'},
          'elasticsearch': {'node_attributes': {'data': 'hot'}}
        }]
      }
    }],
    'kibana': [{
      'ref_id': 'main-kibana',
      'elasticsearch_cluster_ref_id': 'main-elasticsearch',
      'region': '${REGION}',
      'plan': {
        'kibana': {},
        'cluster_topology': [{
          'instance_configuration_id': 'aws.kibana.c8gd',
          'size': {'value': 1024, 'resource': 'memory'},
          'zone_count': 1
        }]
      }
    }],
    'integrations_server': [{
      'ref_id': 'main-integrations_server',
      'elasticsearch_cluster_ref_id': 'main-elasticsearch',
      'region': '${REGION}',
      'plan': {
        'integrations_server': {},
        'cluster_topology': [{
          'instance_configuration_id': 'aws.integrationsserver.c8gd',
          'size': {'value': 1024, 'resource': 'memory'},
          'zone_count': 1
        }]
      }
    }]
  }
}
print(json.dumps(spec))
")

    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /tmp/profiling_deploy_resp.json -w "%{http_code}" \
      -X POST "${EC_API}/deployments?version=${STACK_VER}" \
      -H "Authorization: ApiKey ${EC_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "${DEPLOY_BODY}")

    if [[ "${HTTP_CODE}" =~ ^2 ]]; then
      PROFILING_DID=$(python3 -c "import json; print(json.load(open('/tmp/profiling_deploy_resp.json'))['id'])" 2>/dev/null)
      echo "  ✓ Deployment created (${PROFILING_DID})"
    else
      echo "  ✗ Failed to create deployment (HTTP ${HTTP_CODE}):" >&2
      cat /tmp/profiling_deploy_resp.json >&2
      rm -f /tmp/profiling_deploy_resp.json
      return 1
    fi
    rm -f /tmp/profiling_deploy_resp.json
  fi

  update_env "PROFILING_DEPLOYMENT_ID" "${PROFILING_DID}"

  # Wait for healthy + fetch URLs and credentials
  echo "  Waiting for deployment to become healthy (up to 10 min)..."
  local ATTEMPTS=0 STATUS="" KIBANA_URL="" ES_URL="" ES_PASS="" ES_USER=""
  while [[ ${ATTEMPTS} -lt 60 ]]; do
    local INFO
    INFO=$(curl -sf "${EC_API}/deployments/${PROFILING_DID}" \
      -H "Authorization: ApiKey ${EC_API_KEY}" 2>/dev/null || echo "")
    if [[ -z "${INFO}" ]]; then
      sleep 10; ATTEMPTS=$((ATTEMPTS+1)); continue
    fi

    STATUS=$(echo "${INFO}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
# Check if all resources are started
recs = d.get('resources', {})
statuses = []
for kind in ('elasticsearch', 'kibana', 'integrations_server'):
    for r in recs.get(kind, []):
        for info in r.get('info', {}).get('plan_info', {}).get('current', {}).get('plan_attempt_log', []):
            pass  # not useful here
        health = r.get('info', {}).get('status', '')
        statuses.append(health)
print('healthy' if all(s == 'started' for s in statuses if s) and statuses else 'pending')
" 2>/dev/null || echo "pending")

    if [[ "${STATUS}" == "healthy" ]]; then
      # Extract endpoint URLs
      ES_URL=$(echo "${INFO}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('resources', {}).get('elasticsearch', []):
    ep = r.get('info', {}).get('metadata', {}).get('endpoint', '')
    if ep: print('https://' + ep); break
" 2>/dev/null || echo "")
      KIBANA_URL=$(echo "${INFO}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('resources', {}).get('kibana', []):
    ep = r.get('info', {}).get('metadata', {}).get('endpoint', '')
    if ep: print('https://' + ep); break
" 2>/dev/null || echo "")
      break
    fi

    echo -n "."
    sleep 10; ATTEMPTS=$((ATTEMPTS+1))
  done

  if [[ "${STATUS}" != "healthy" || -z "${KIBANA_URL}" ]]; then
    # Deployment still in progress — fetch what we can
    local LATEST_INFO
    LATEST_INFO=$(curl -sf "${EC_API}/deployments/${PROFILING_DID}" \
      -H "Authorization: ApiKey ${EC_API_KEY}" 2>/dev/null || echo "")
    ES_URL=$(echo "${LATEST_INFO}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('resources', {}).get('elasticsearch', []):
    ep = r.get('info', {}).get('metadata', {}).get('endpoint', '')
    if ep: print('https://' + ep); break
" 2>/dev/null || echo "")
    KIBANA_URL=$(echo "${LATEST_INFO}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('resources', {}).get('kibana', []):
    ep = r.get('info', {}).get('metadata', {}).get('endpoint', '')
    if ep: print('https://' + ep); break
" 2>/dev/null || echo "")
    if [[ -z "${KIBANA_URL}" ]]; then
      echo ""
      echo "  ✗ Timed out waiting for deployment — check Elastic Cloud console" >&2
      echo "    Deployment ID: ${PROFILING_DID}"
      return 1
    fi
    echo ""
    echo "  ⚠ Deployment still initialising — URLs available, continuing..."
  else
    echo ""
    echo "  ✓ Deployment healthy"
  fi

  # Reset credentials and capture password
  echo "  Resetting credentials for deployment ${PROFILING_DID}..."
  local RESET_RESP
  RESET_RESP=$(curl -sf -X POST \
    "${EC_API}/deployments/${PROFILING_DID}/elasticsearch/main-elasticsearch/_reset-password" \
    -H "Authorization: ApiKey ${EC_API_KEY}" 2>/dev/null || echo "")
  ES_USER=$(echo "${RESET_RESP}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('username','elastic'))" 2>/dev/null || echo "elastic")
  ES_PASS=$(echo "${RESET_RESP}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('password',''))" 2>/dev/null || echo "")

  if [[ -z "${ES_PASS}" ]]; then
    echo "  ✗ Could not reset credentials" >&2
    return 1
  fi

  update_env "PROFILING_KIBANA_URL" "${KIBANA_URL}"
  update_env "PROFILING_ES_URL" "${ES_URL}"
  update_env "PROFILING_ES_USER" "${ES_USER}"
  update_env "PROFILING_ES_PASSWORD" "${ES_PASS}"

  echo "  ✓ Stateful ESS deployment ready"
  echo "    Kibana  : ${KIBANA_URL}"
  echo "    ES      : ${ES_URL}"
  echo "    Deploy  : ${PROFILING_DID}"

  _provision_profiling_fleet "${STACK_VER}"
}

_provision_profiling_fleet() {
  local KIBANA="${PROFILING_KIBANA_URL}"
  local ES_USER="${PROFILING_ES_USER:-elastic}"
  local ES_PASS="${PROFILING_ES_PASSWORD}"
  local STACK_VER="$1"
  local POLICY_NAME="ecomm-otel — Universal Profiling Host"

  echo "→ Configuring Fleet in stateful deployment"

  # Wait for Kibana (up to 5 min)
  local ATTEMPTS=0
  echo -n "  Waiting for Kibana"
  while [[ ${ATTEMPTS} -lt 30 ]]; do
    if curl -sf "${KIBANA}/api/status" -u "${ES_USER}:${ES_PASS}" -o /dev/null 2>/dev/null; then
      echo " ✓"
      break
    fi
    echo -n "."
    sleep 10
    ATTEMPTS=$((ATTEMPTS+1))
  done
  if [[ ${ATTEMPTS} -ge 30 ]]; then
    echo ""
    echo "  ✗ Kibana did not become ready in 5 min" >&2
    return 1
  fi

  # Get Fleet server URL — retry because Fleet initialises after Kibana reports healthy
  local FLEET_SERVER_URL="" FLEET_ATTEMPTS=0
  echo -n "  Waiting for Fleet"
  while [[ ${FLEET_ATTEMPTS} -lt 12 && -z "${FLEET_SERVER_URL}" ]]; do
    FLEET_SERVER_URL=$(curl -sf "${KIBANA}/api/fleet/fleet_server_hosts" \
      -u "${ES_USER}:${ES_PASS}" 2>/dev/null | python3 -c "
import json, sys
items = json.load(sys.stdin).get('items', [])
default = next((i for i in items if i.get('is_default') and not i.get('is_preconfigured')), None)
if not default:
    default = next((i for i in items if i.get('is_default')), None)
print(default['host_urls'][0] if default and default.get('host_urls') else '')
" 2>/dev/null || echo "")
    if [[ -z "${FLEET_SERVER_URL}" ]]; then
      echo -n "."
      sleep 15
      FLEET_ATTEMPTS=$((FLEET_ATTEMPTS+1))
    fi
  done

  if [[ -z "${FLEET_SERVER_URL}" ]]; then
    echo ""
    echo "  ✗ Could not retrieve Fleet server URL from stateful deployment" >&2
    return 1
  fi
  echo " ✓"
  update_env "PROFILING_FLEET_URL" "${FLEET_SERVER_URL}"
  echo "  ✓ Fleet URL: ${FLEET_SERVER_URL}"

  # Create (or find) agent policy
  local POLICY_ID
  POLICY_ID=$(curl -sf "${KIBANA}/api/fleet/agent_policies?perPage=100" \
    -u "${ES_USER}:${ES_PASS}" 2>/dev/null | python3 -c "
import json, sys
items = json.load(sys.stdin).get('items', [])
match = next((i for i in items if i.get('name') == '${POLICY_NAME}'), None)
print(match['id'] if match else '')
" 2>/dev/null || echo "")

  if [[ -n "${POLICY_ID}" ]]; then
    echo "  – agent policy already exists (${POLICY_ID})"
  else
    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /tmp/pp_policy.json -w "%{http_code}" \
      -X POST "${KIBANA}/api/fleet/agent_policies" \
      -u "${ES_USER}:${ES_PASS}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
      -d "{\"name\":\"${POLICY_NAME}\",\"namespace\":\"default\",\"description\":\"EC2 profiling host — Universal Profiling\"}")
    if [[ "${HTTP_CODE}" =~ ^2 ]]; then
      POLICY_ID=$(python3 -c "import json; print(json.load(open('/tmp/pp_policy.json'))['item']['id'])" 2>/dev/null)
      echo "  ✓ agent policy created (${POLICY_ID})"
    else
      echo "  ✗ failed to create agent policy (HTTP ${HTTP_CODE}): $(cat /tmp/pp_policy.json 2>/dev/null)" >&2
      rm -f /tmp/pp_policy.json; return 1
    fi
  fi
  rm -f /tmp/pp_policy.json

  # Attach system integration (idempotent)
  local SYS_VERSION="${SYSTEM_INTEGRATION_VERSION:-1.62.0}"
  local SYS_EXISTING
  SYS_EXISTING=$(curl -sf "${KIBANA}/api/fleet/package_policies?kuery=name:\"profiling-system-host\"" \
    -u "${ES_USER}:${ES_PASS}" 2>/dev/null | python3 -c "
import json, sys
items = [i for i in json.load(sys.stdin).get('items', []) if i.get('policy_id') == '${POLICY_ID}']
print(items[0]['id'] if items else '')
" 2>/dev/null || echo "")

  if [[ -n "${SYS_EXISTING}" ]]; then
    echo "  – system integration already attached"
  else
    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /tmp/pp_sys.json -w "%{http_code}" \
      -X POST "${KIBANA}/api/fleet/package_policies" \
      -u "${ES_USER}:${ES_PASS}" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
      -d "{\"name\":\"profiling-system-host\",\"namespace\":\"default\",\"policy_id\":\"${POLICY_ID}\",\"package\":{\"name\":\"system\",\"version\":\"${SYS_VERSION}\"},\"inputs\":{}}")
    if [[ "${HTTP_CODE}" =~ ^2 ]] || [[ "${HTTP_CODE}" == "409" ]]; then
      echo "  ✓ system integration attached"
    else
      echo "  ✗ system integration failed (HTTP ${HTTP_CODE}) — continuing anyway" >&2
    fi
    rm -f /tmp/pp_sys.json
  fi

  # Get enrollment token
  local TOKEN
  TOKEN=$(curl -sf "${KIBANA}/api/fleet/enrollment_api_keys?kuery=policy_id:\"${POLICY_ID}\"" \
    -u "${ES_USER}:${ES_PASS}" 2>/dev/null | python3 -c "
import json, sys
items = json.load(sys.stdin).get('items', [])
print(items[0]['api_key'] if items else '')
" 2>/dev/null || echo "")

  if [[ -z "${TOKEN}" ]]; then
    echo "  ✗ Could not retrieve Fleet enrollment token" >&2
    return 1
  fi
  update_env "PROFILING_FLEET_ENROLLMENT_TOKEN" "${TOKEN}"
  echo "  ✓ enrollment token saved to .env"

  _ssm_reenroll_profiling "${FLEET_SERVER_URL}" "${TOKEN}" "${STACK_VER}"
}

_ssm_reenroll_profiling() {
  local FLEET_URL="$1"
  local TOKEN="$2"
  local STACK_VER="$3"

  echo "→ Re-enrolling EC2 agent to stateful deployment"
  local INSTANCE_ID REGION
  REGION="${AWS_REGION:-eu-central-1}"
  INSTANCE_ID=$(cd "${ROOT_DIR}/infra/aws" && terraform output -raw profiling_host_instance_id 2>/dev/null || echo "")
  if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "pending" ]]; then
    echo "  ✗ EC2 profiling host not provisioned — run 'apply-aws' first, then re-run provision-profiling-deployment" >&2
    echo "  Enrollment token saved to .env as PROFILING_FLEET_ENROLLMENT_TOKEN — run 'provision-profiling-deployment' again after 'apply-aws'"
    return 0
  fi

  # Re-enroll the existing agent (don't reinstall — Elastic Cloud auto-picks the latest
  # compatible version which matches the agent already on the host)
  local PARAMS
  PARAMS=$(python3 -c "
import json
cmds = [
    'set -e',
    'systemctl stop elastic-agent 2>/dev/null || true',
    'sleep 2',
    'elastic-agent enroll --url=\"${FLEET_URL}\" --enrollment-token=\"${TOKEN}\" --force',
    'systemctl enable elastic-agent && systemctl start elastic-agent',
    'sleep 3',
    'systemctl is-active elastic-agent && echo \"Re-enrollment complete\" || echo \"Service not yet active — check systemctl status elastic-agent\"',
]
print(json.dumps({'commands': cmds}))
" 2>/dev/null)

  local CMD_ID
  CMD_ID=$(aws ssm send-command \
    --region "${REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" \
    --cli-input-json "{\"DocumentName\":\"AWS-RunShellScript\",\"InstanceIds\":[\"${INSTANCE_ID}\"],\"Parameters\":${PARAMS},\"TimeoutSeconds\":300}" \
    --output text \
    --query "Command.CommandId" 2>&1 || echo "")

  if [[ -z "${CMD_ID}" ]] || echo "${CMD_ID}" | grep -q "Error\|error"; then
    echo "  ✗ SSM re-enrollment failed:"
    echo "    ${CMD_ID}" >&2
    return 1
  fi

  echo "  SSM command ID: ${CMD_ID}"
  echo "  ✓ Re-enrollment running. Poll with:"
  echo "    aws ssm get-command-invocation --command-id ${CMD_ID} --instance-id ${INSTANCE_ID} --region ${REGION}"
  echo ""
  echo "  Next steps:"
  echo "  1. Wait ~2 min for the agent to check in to the stateful Fleet"
  echo "  2. In Kibana (${PROFILING_KIBANA_URL:-see .env PROFILING_KIBANA_URL}):"
  echo "     Fleet > Integrations > search 'Universal Profiling'"
  echo "     Add the 'Universal Profiling' integration to the '${POLICY_NAME:-ecomm-otel — Universal Profiling Host}' policy"
  echo "  3. Flame graphs appear in: Observability > Universal Profiling"
  echo "  4. Trigger slow mode: ./scripts/demo.sh trigger-incident"
  echo "     (FraudShield fraudShieldApiCall() will dominate the flame graph)"
}

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

  # Mirror slow mode on the profiling host so the flame graph tells the same story
  _ssm_run "touch /tmp/fraud_check_slow && echo profiling slow mode enabled"
  echo "  → Profiling host: slow mode enabled (fraudShieldApiCall will dominate flame graph)"
  echo "  Run './scripts/demo.sh reset' to restore normal behaviour."

  if [[ -n "${KIBANA_URL:-}" && -n "${ELASTIC_INGEST_API_KEY:-}" ]]; then
    echo "  → Autonomous SRE investigation starting in the background"
    echo "    (log: ${ROOT_DIR}/.autonomous-sre.log)"
    ( _run_autonomous_investigation >> "${ROOT_DIR}/.autonomous-sre.log" 2>&1 & disown )
  fi

  # Post a deployment annotation to APM so the incident correlates to a "deploy event" on the timeline
  if [[ -n "${KIBANA_URL:-}" && -n "${ELASTIC_INGEST_API_KEY:-}" ]]; then
    local ANNO_TS
    ANNO_TS=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    curl -s -o /dev/null -X POST "${KIBANA_URL}/api/apm/services/checkout-service/annotation" \
      -H "Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}" \
      -H "Content-Type: application/json" \
      -H "kbn-xsrf: true" \
      -d "{\"@timestamp\": \"${ANNO_TS}\", \"service\": {\"version\": \"2.4.1\"}, \"message\": \"Deploy: realtime_fraud_detection=true (PR #47 — FraudShield integration)\"}" \
      && echo "  → Deployment annotation posted to APM (checkout-service v2.4.1)"
  fi
}

reset_demo() {
  local FLAG_URL="${FLAG_SERVICE_URL:-http://localhost:8090}"
  curl -sf -X POST "${FLAG_URL}/flags/reset" | python3 -m json.tool

  # Clear profiling slow mode
  _ssm_run "rm -f /tmp/fraud_check_slow && echo profiling slow mode cleared"

  echo "✓ Demo reset complete"
}

# ── Ingest pipeline provisioning ─────────────────────────────────────────────
provision_ingest_pipelines() {
  echo "→ Provisioning ingest pipelines"
  local ES="${ELASTICSEARCH_URL}"
  local AUTH="Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}"
  local PIPELINES_DIR="${ROOT_DIR}/platform/ingest-pipelines"

  for PIPELINE_FILE in "${PIPELINES_DIR}"/*.json; do
    [[ -f "${PIPELINE_FILE}" ]] || continue
    local PIPELINE_ID
    PIPELINE_ID=$(basename "${PIPELINE_FILE}" .json)

    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /tmp/pipeline_resp.json -w "%{http_code}" \
      -X PUT "${ES}/_ingest/pipeline/${PIPELINE_ID}" \
      -H "${AUTH}" -H "Content-Type: application/json" \
      --data-binary "@${PIPELINE_FILE}")

    if [[ "${HTTP_CODE}" =~ ^2 ]]; then
      echo "  ✓ ${PIPELINE_ID}"
    else
      echo "  ✗ ${PIPELINE_ID} (HTTP ${HTTP_CODE}): $(cat /tmp/pipeline_resp.json 2>/dev/null | head -1)"
      rm -f /tmp/pipeline_resp.json
      return 1
    fi

    # Apply as default_pipeline on the traces index so new spans are automatically redacted
    HTTP_CODE=$(curl -s -o /tmp/idx_resp.json -w "%{http_code}" \
      -X PUT "${ES}/traces-generic.otel-default/_settings" \
      -H "${AUTH}" -H "Content-Type: application/json" \
      -d "{\"index\": {\"default_pipeline\": \"${PIPELINE_ID}\"}}")

    if [[ "${HTTP_CODE}" =~ ^2 ]]; then
      echo "  ✓ ${PIPELINE_ID} set as default_pipeline on traces-generic.otel-default"
    else
      echo "  ✗ Failed to set default_pipeline (HTTP ${HTTP_CODE}): $(cat /tmp/idx_resp.json 2>/dev/null | head -1)"
    fi

    rm -f /tmp/pipeline_resp.json /tmp/idx_resp.json
  done
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${1:-}" in
  build)            build_all ;;
  teardown)         teardown_all ;;
  apply)            tf_apply ;;
  destroy)          tf_destroy ;;
  apply-aws)                 tf_apply_aws ;;
  apply-profiling-host)      tf_apply_profiling_host ;;
  deploy-profiling-stress)   deploy_profiling_stress ;;
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
  provision-knowledge-base)  provision_knowledge_base ;;
  provision-agent-builder)   provision_agent_builder ;;
  provision-workflows)       provision_workflows ;;
  provision-spaces)          provision_spaces ;;
  provision-rbac)            provision_rbac ;;
  provision-product-team)    provision_product_team ;;
  provision-team)            provision_team "checkout" "product-team" ;;
  provision-profiling-deployment) provision_profiling_deployment ;;
  provision-ingest-pipelines) provision_ingest_pipelines ;;
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
