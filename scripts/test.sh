#!/usr/bin/env bash
# Smoke-test suite for ecomm-otel demo.
# Run standalone: ./scripts/test.sh
# Or via demo.sh: ./scripts/demo.sh test
#
# Each test prints PASS / FAIL / SKIP.
# Exit code = number of failures (0 = all pass).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a; source "${ROOT_DIR}/.env"; set +a
fi

PASS=0; FAIL=0; SKIP=0
ES_URL="${ELASTICSEARCH_URL:-}"
KIBANA_URL="${KIBANA_URL:-}"
ELASTIC_INGEST_API_KEY="${ELASTIC_INGEST_API_KEY:-}"
PT_ES_URL="${PRODUCT_TEAM_ES_URL:-}"
PT_KIBANA_URL="${PRODUCT_TEAM_KIBANA_URL:-}"
PT_API_KEY="${PRODUCT_TEAM_API_KEY:-}"

# ── Helpers ────────────────────────────────────────────────────────────────────

pass() { echo "  ✓ PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ FAIL  $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  –  SKIP  $1"; SKIP=$((SKIP + 1)); }

section() { echo ""; echo "▶ $1"; }

es_curl() {
  curl -sf \
    -H "Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}" \
    -H "Content-Type: application/json" \
    "$@"
}

es_count() {
  local PATTERN="$1"
  local BODY="${2:-{\"query\":{\"match_all\":{}}}}"
  local RESP; RESP=$(es_curl -X POST "${ES_URL}/${PATTERN}/_count" -d "${BODY}" 2>/dev/null) || true
  echo "${RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0"
}

es_hit() {
  local PATTERN="$1"
  local BODY="${2:-{\"size\":1}}"
  local RESP; RESP=$(es_curl -X POST "${ES_URL}/${PATTERN}/_search" -d "${BODY}" 2>/dev/null) || true
  echo "${RESP}" | python3 -c "import sys,json; hits=json.load(sys.stdin)['hits']['hits']; print(json.dumps(hits[0]['_source']) if hits else 'null')" 2>/dev/null || echo "null"
}

http_status() {
  # No -f: we want the real status code on 4xx/5xx, not just a curl failure.
  # curl itself prints "000" via %{http_code} when no response is received,
  # so the || fallback only covers curl invocation errors.
  curl -s -o /dev/null -w "%{http_code}" "$@" 2>/dev/null || echo "000"
}

# ── INFRASTRUCTURE ─────────────────────────────────────────────────────────────

section "Infrastructure: containers"

REQUIRED_CONTAINERS=(
  "ecomm-otel-collector-1"
  "ecomm-otel-api-gateway-1"
  "ecomm-otel-storefront-1"
  "ecomm-otel-feature-flag-service-1"
  "ecomm-otel-product-service-1"
  "ecomm-otel-checkout-service-1"
  "ecomm-otel-order-service-1"
  "ecomm-otel-notification-service-1"
  "ecomm-otel-kafka-1"
)

for CONTAINER in "${REQUIRED_CONTAINERS[@]}"; do
  STATUS=$(docker inspect "${CONTAINER}" --format "{{.State.Status}}" 2>/dev/null || echo "missing")
  if [[ "${STATUS}" == "running" ]]; then
    pass "${CONTAINER} is running"
  else
    fail "${CONTAINER} is ${STATUS}"
  fi
done

section "Infrastructure: collector health"

HEALTH=$(http_status "http://localhost:13134")
if [[ "${HEALTH}" == "200" ]]; then
  pass "Collector health check OK"
else
  fail "Collector health check returned HTTP ${HEALTH}"
fi

section "Infrastructure: local service endpoints"

check_endpoint() {
  local NAME="$1" URL="$2"
  local CODE; CODE=$(http_status "${URL}")
  if [[ "${CODE}" =~ ^2 ]]; then
    pass "${NAME} responds (HTTP ${CODE})"
  else
    fail "${NAME} returned HTTP ${CODE} at ${URL}"
  fi
}

check_endpoint "storefront"          "http://localhost:3000"
check_endpoint "api-gateway"         "http://localhost:8080/health"
check_endpoint "feature-flag-service" "http://localhost:8090/flags"

# ── DATA PIPELINE ──────────────────────────────────────────────────────────────

section "Data pipeline: OTel data landing in Elastic"

if [[ -z "${ES_URL}" ]]; then
  skip "ELASTICSEARCH_URL not set — skipping Elastic checks"
else
  TRACE_COUNT=$(es_count "traces-*")
  if [[ "${TRACE_COUNT}" -gt 0 ]]; then
    pass "traces-* has ${TRACE_COUNT} documents"
  else
    fail "traces-* is empty — collector may not be exporting"
  fi

  LOG_COUNT=$(es_count "logs*")
  if [[ "${LOG_COUNT}" -gt 0 ]]; then
    pass "logs* has ${LOG_COUNT} documents"
  else
    fail "logs* is empty"
  fi

  METRIC_COUNT=$(es_count "metrics-*")
  if [[ "${METRIC_COUNT}" -gt 0 ]]; then
    pass "metrics-* has ${METRIC_COUNT} documents"
  else
    fail "metrics-* is empty"
  fi

  # Check data is recent (within 5 minutes)
  RECENT_QUERY='{"query":{"range":{"@timestamp":{"gte":"now-5m"}}}}'
  RECENT=$(es_count "traces-*" "${RECENT_QUERY}")
  if [[ "${RECENT}" -gt 0 ]]; then
    pass "Traces are being written in the last 5 minutes (${RECENT} recent)"
  else
    fail "No traces in the last 5 minutes — pipeline may be stalled"
  fi
fi

# ── UC1: END-TO-END INVESTIGATION ─────────────────────────────────────────────

section "UC1: Distributed tracing — service coverage"

if [[ -z "${ES_URL}" ]]; then
  skip "ELASTICSEARCH_URL not set"
else
  for SVC in "api-gateway" "product-service" "checkout-service" "order-service" "feature-flag-service"; do
    QUERY="{\"query\":{\"term\":{\"resource.attributes.service.name\":\"${SVC}\"}}}"
    COUNT=$(es_count "traces-*" "${QUERY}")
    if [[ "${COUNT}" -gt 0 ]]; then
      pass "${SVC} spans present (${COUNT})"
    else
      fail "${SVC} has no spans in traces-*"
    fi
  done
fi


section "UC1: Feature flag service"

FLAG_STATUS=$(http_status "http://localhost:8090/flags")
if [[ "${FLAG_STATUS}" == "200" ]]; then
  pass "Feature flag service responds"
else
  fail "Feature flag service returned HTTP ${FLAG_STATUS}"
fi

FLAG_RESP=$(curl -sf "http://localhost:8090/flags" 2>/dev/null || echo "{}")
FRAUD_FLAG=$(echo "${FLAG_RESP}" | python3 -c "
import sys, json
flags = json.load(sys.stdin)
if isinstance(flags, list):
    match = [f for f in flags if f.get('name') == 'realtime_fraud_detection']
    print(match[0].get('value', 'missing') if match else 'missing')
elif isinstance(flags, dict):
    print(flags.get('realtime_fraud_detection', 'missing'))
else:
    print('missing')
" 2>/dev/null || echo "error")
if [[ "${FRAUD_FLAG}" != "missing" && "${FRAUD_FLAG}" != "error" ]]; then
  pass "realtime_fraud_detection flag is present (value: ${FRAUD_FLAG})"
else
  fail "realtime_fraud_detection flag not found in feature-flag-service response"
fi

section "UC1: PII masking — no raw card numbers or emails in traces"

if [[ -z "${ES_URL}" ]]; then
  skip "ELASTICSEARCH_URL not set"
else
  # Check that no checkout spans contain a raw 16-digit card number
  RAW_CARDS=$(es_count "traces-*" '{
    "query": {"bool": {"must": [
      {"term": {"resource.attributes.service.name": "checkout-service"}},
      {"regexp": {"attributes.card.number.keyword": "[0-9]{16}"}}
    ]}}
  }')
  if [[ "${RAW_CARDS}" == "0" ]]; then
    pass "No unmasked 16-digit card numbers in checkout spans"
  else
    fail "Found ${RAW_CARDS} span(s) with unmasked card numbers — PII pipeline not active"
  fi

  # Check that no spans contain raw email addresses in body / log fields
  RAW_EMAILS=$(es_count "traces-*" '{
    "query": {"regexp": {"attributes.user.email.keyword": ".+@.+\\..+"}}
  }')
  if [[ "${RAW_EMAILS}" == "0" ]]; then
    pass "No unmasked email addresses in trace attributes"
  else
    fail "Found ${RAW_EMAILS} span(s) with unmasked email addresses — PII pipeline not active"
  fi
fi

section "UC1: Kafka — order events"

if [[ -z "${ES_URL}" ]]; then
  skip "ELASTICSEARCH_URL not set"
else
  # OTel semantic convention: messaging.system=kafka (stored as span attributes)
  # Try both field paths — EDOT may store as attributes.messaging.system or span.attributes.messaging.system
  KAFKA_OTEL='{"query":{"bool":{"should":[
    {"term":{"attributes.messaging.system":"kafka"}},
    {"term":{"span.attributes.messaging.system":"kafka"}},
    {"term":{"span.subtype":"kafka"}}
  ],"minimum_should_match":1}}}'
  KAFKA_COUNT=$(es_count "traces-*" "${KAFKA_OTEL}")
  if [[ "${KAFKA_COUNT}" -gt 0 ]]; then
    pass "Kafka spans present (${KAFKA_COUNT}) — order event pipeline traced"
  else
    fail "No Kafka spans in traces — order-service or notification-service not emitting"
  fi
fi

# ── UC2: SLOs ─────────────────────────────────────────────────────────────────

section "UC2: SLOs defined in Kibana"

if [[ -z "${KIBANA_URL}" ]]; then
  skip "KIBANA_URL not set"
else
  SLO_RESP=$(curl -sf \
    -H "Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}" \
    -H "kbn-xsrf: true" \
    "${KIBANA_URL}/api/observability/slos?size=20" 2>/dev/null || echo '{"total":0,"results":[]}')

  SLO_COUNT=$(echo "${SLO_RESP}" | python3 -c "
import sys,json; d=json.load(sys.stdin); print(d.get('total',0))" 2>/dev/null || echo "0")
  if [[ "${SLO_COUNT}" -ge 4 ]]; then
    pass "${SLO_COUNT} SLO(s) defined in Kibana (expected ≥ 4)"
  else
    fail "${SLO_COUNT} SLO(s) defined — expected at least 4 (checkout latency, errors, API GW, order fulfilment)"
  fi

  # Verify checkout latency SLO objective is 99.9% (not the old 99%)
  LATENCY_TARGET=$(echo "${SLO_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for r in d.get('results',[]):
    if 'P99 Latency' in r.get('name','') or 'Latency' in r.get('name',''):
        print(r.get('objective',{}).get('target','?')); break
else:
    print('not_found')
" 2>/dev/null || echo "error")
  if [[ "${LATENCY_TARGET}" == "0.999" ]]; then
    pass "Checkout latency SLO objective is 99.9% ✓"
  elif [[ "${LATENCY_TARGET}" == "not_found" ]]; then
    fail "Checkout latency SLO not found"
  else
    fail "Checkout latency SLO objective is ${LATENCY_TARGET} — expected 0.999"
  fi
fi

section "UC2: Alert rules defined and Slack-wired"

if [[ -z "${KIBANA_URL}" ]]; then
  skip "KIBANA_URL not set"
else
  RULES_RESP=$(curl -sf \
    -H "Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}" \
    -H "kbn-xsrf: true" \
    "${KIBANA_URL}/api/alerting/rules/_find?page_size=50" 2>/dev/null || echo '{"total":0,"data":[]}')

  RULE_COUNT=$(echo "${RULES_RESP}" | python3 -c "
import sys,json; d=json.load(sys.stdin); print(d.get('total',0))" 2>/dev/null || echo "0")
  if [[ "${RULE_COUNT}" -ge 4 ]]; then
    pass "${RULE_COUNT} alert rule(s) defined (expected ≥ 4)"
  else
    fail "${RULE_COUNT} alert rule(s) — expected at least 4 (error spike, latency spike, checkout SLO burn rate, order fulfilment burn rate)"
  fi

  # Check Slack wiring — only if SLACK_TOKEN is configured
  if [[ -n "${SLACK_TOKEN:-}" ]]; then
    SLACK_WIRED=$(echo "${RULES_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
wired=[r['name'] for r in d.get('data',[]) if r.get('actions')]
print(len(wired))
" 2>/dev/null || echo "0")
    if [[ "${SLACK_WIRED}" -ge 4 ]]; then
      pass "${SLACK_WIRED} alert rule(s) have Slack actions wired"
    else
      fail "${SLACK_WIRED}/4 alert rules have actions — run 'provision-alerts' to wire Slack"
    fi
  else
    skip "SLACK_TOKEN not set — skipping Slack action check"
  fi
fi

# ── UC5: Autonomous SRE (knowledge base + Agent Builder + workflow) ────────────

section "UC5: Knowledge base — runbook docs indexed"

if [[ -z "${ES_URL}" ]]; then
  skip "ELASTICSEARCH_URL not set"
else
  KB_COUNT=$(es_count "sre-runbooks")
  if [[ "${KB_COUNT}" -ge 3 ]]; then
    pass "sre-runbooks has ${KB_COUNT} doc(s)"
  else
    fail "sre-runbooks has ${KB_COUNT} doc(s) — expected ≥ 3 (run provision-knowledge-base)"
  fi
fi

section "UC5: Agent Builder — autonomous-SRE agent and tool exist"

if [[ -z "${KIBANA_URL}" ]]; then
  skip "KIBANA_URL not set"
else
  AGENT_CODE=$(http_status -H "Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}" -H "kbn-xsrf: true" \
    "${KIBANA_URL}/api/agent_builder/agents/ecomm-sre-rca")
  if [[ "${AGENT_CODE}" == "200" ]]; then
    pass "ecomm-sre-rca agent present"
  else
    fail "ecomm-sre-rca agent missing (HTTP ${AGENT_CODE}) — run provision-agent-builder"
  fi

  TOOL_CODE=$(http_status -H "Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}" -H "kbn-xsrf: true" \
    "${KIBANA_URL}/api/agent_builder/tools/search_runbooks")
  if [[ "${TOOL_CODE}" == "200" ]]; then
    pass "search_runbooks tool present"
  else
    fail "search_runbooks tool missing (HTTP ${TOOL_CODE}) — run provision-agent-builder"
  fi
fi

section "UC5: Workflow exists and is enabled"

if [[ -z "${KIBANA_URL}" ]]; then
  skip "KIBANA_URL not set"
else
  WF_RESP=$(curl -sf -H "Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}" -H "kbn-xsrf: true" \
    "${KIBANA_URL}/api/workflows?query=ecomm-otel" 2>/dev/null || echo '{}')
  WF_STATE=$(echo "${WF_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
w=next((w for w in d.get('results', d.get('data',[])) if w.get('name')=='ecomm-otel--autonomous-sre-rca'), None)
print('yes' if w and w.get('enabled') else ('disabled' if w else 'missing'))" 2>/dev/null || echo "error")
  case "${WF_STATE}" in
    yes)      pass "Autonomous SRE workflow present and enabled" ;;
    disabled) fail "Autonomous SRE workflow exists but is disabled" ;;
    *)        fail "Autonomous SRE workflow ${WF_STATE} — run provision-workflows" ;;
  esac
fi

# ── UC3: IaC / GitOps ─────────────────────────────────────────────────────────

section "UC3: GitOps layer structure"

if [[ -d "${ROOT_DIR}/platform" ]]; then
  CONFIG_FILES=$(find "${ROOT_DIR}/platform" -name "*.tf" -o -name "*.json" -o -name "*.yml" | wc -l | tr -d ' ')
  if [[ "${CONFIG_FILES}" -gt 0 ]]; then
    pass "platform/ layer exists with ${CONFIG_FILES} config file(s)"
  else
    fail "platform/ directory exists but is empty"
  fi
else
  fail "platform/ directory missing — UC3 (GitOps) not started"
fi

if [[ -d "${ROOT_DIR}/teams/checkout" ]]; then
  pass "teams/checkout/ layer exists"
else
  fail "teams/checkout/ directory missing — UC3 team-layer not started"
fi

# ── UC3: Product team project ─────────────────────────────────────────────────

section "UC3: Product team project — endpoints configured"

if [[ -z "${PT_ES_URL}" || -z "${PT_KIBANA_URL}" ]]; then
  skip "PRODUCT_TEAM_ES_URL / PRODUCT_TEAM_KIBANA_URL not set — run 'provision-product-team'"
else
  # _cluster/health is not available on Serverless (api_not_available_exception).
  # Root endpoint is a lightweight, Serverless-compatible reachability check.
  PT_ES_STATUS=$(http_status -H "Authorization: ApiKey ${PT_API_KEY}" "${PT_ES_URL}/")
  if [[ "${PT_ES_STATUS}" == "200" ]]; then
    pass "Product team Elasticsearch reachable"
  else
    fail "Product team Elasticsearch returned HTTP ${PT_ES_STATUS}"
  fi

  PT_KB_STATUS=$(http_status \
    -H "Authorization: ApiKey ${PT_API_KEY}" \
    -H "kbn-xsrf: true" \
    "${PT_KIBANA_URL}/api/status")
  if [[ "${PT_KB_STATUS}" == "200" ]]; then
    pass "Product team Kibana reachable"
  else
    fail "Product team Kibana returned HTTP ${PT_KB_STATUS}"
  fi
fi

section "UC3: Cross-Project Search — product team queries platform traces"

if [[ -z "${PT_ES_URL}" || -z "${EC_API_KEY:-}" ]]; then
  skip "Product team credentials not set — run 'provision-product-team'"
else
  # CPS is unavailable to project-scoped Elasticsearch API keys (PT_API_KEY) —
  # it requires an Elastic Cloud API key with "Cloud, Elasticsearch, and Kibana
  # API" access, scoped to both projects. EC_API_KEY is that key.
  CPS_RESP=$(curl -sf -X POST \
    -H "Authorization: ApiKey ${EC_API_KEY}" \
    -H "Content-Type: application/json" \
    "${PT_ES_URL}/_query" \
    -d '{"query":"FROM traces-generic.otel-default | STATS count = COUNT(*) | LIMIT 1"}' \
    2>/dev/null || echo '{}')
  CPS_COUNT=$(echo "${CPS_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
rows=d.get('values',[[0]])
print(rows[0][0] if rows else 0)" 2>/dev/null || echo "0")
  if [[ "${CPS_COUNT}" -gt 0 ]]; then
    pass "CPS ES|QL query returns ${CPS_COUNT} trace(s) from platform project"
  else
    fail "CPS query returned 0 — cross-project search not working or no data"
  fi
fi

section "UC3: Product team Kibana — Checkout Business Overview dashboard deployed"

if [[ -z "${PT_KIBANA_URL}" || -z "${PT_API_KEY}" ]]; then
  skip "Product team credentials not set — run 'provision-product-team'"
else
  # _find is unavailable on this Serverless build; use _export instead.
  DASH_RESP=$(curl -sf -X POST \
    -H "Authorization: ApiKey ${PT_API_KEY}" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    "${PT_KIBANA_URL}/api/saved_objects/_export" \
    -d '{"type":["dashboard"]}' \
    2>/dev/null || echo "")
  DASH_COUNT=$(echo "${DASH_RESP}" | grep -c '"title":"Checkout Business Overview"' || echo "0")
  if [[ "${DASH_COUNT}" -gt 0 ]]; then
    pass "Checkout Business Overview dashboard present in product team Kibana"
  else
    fail "Checkout Business Overview dashboard missing — run 'provision-product-team'"
  fi
fi

# ── UC4: Openness ─────────────────────────────────────────────────────────────

section "UC4: OTel native storage — semantic conventions preserved"

if [[ -z "${ES_URL}" ]]; then
  skip "ELASTICSEARCH_URL not set"
else
  # Verify OTel semantic conventions are preserved: service.name is indexed natively
  # Node.js services use native OTel format; Java/EDOT services use Elastic APM format.
  # We check both: resource.attributes.service.name (native OTel) and service.name (Elastic APM)
  OTEL_NATIVE=$(es_count "traces-*" '{"query":{"exists":{"field":"resource.attributes.service.name"}}}')
  APM_FORMAT=$(es_count "traces-*" '{"query":{"term":{"service.name":"checkout-service"}}}')
  if [[ "${OTEL_NATIVE}" -gt 0 ]]; then
    pass "Native OTel storage confirmed: resource.attributes.service.name present in ${OTEL_NATIVE} spans"
  elif [[ "${APM_FORMAT}" -gt 0 ]]; then
    pass "Elastic APM format confirmed: service.name indexed natively (${APM_FORMAT} checkout spans)"
  else
    fail "No OTel or APM format service fields found — semantic conventions not preserved"
  fi

  # Verify ES|QL is queryable
  ESQL_RESP=$(es_curl -X POST \
    "${ES_URL}/_query" \
    -d '{"query":"FROM traces-* | STATS count = COUNT(*) | LIMIT 1"}' \
    2>/dev/null || echo '{}')
  ESQL_COUNT=$(echo "${ESQL_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
rows=d.get('values',[[0]])
print(rows[0][0] if rows else 0)" 2>/dev/null || echo "0")
  if [[ "${ESQL_COUNT}" -gt 0 ]]; then
    pass "ES|QL query over traces works (${ESQL_COUNT} records)"
  else
    fail "ES|QL query returned 0 — UC4 data access story broken"
  fi
fi

# ── SUMMARY ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────"
TOTAL=$((PASS + FAIL + SKIP))
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped (${TOTAL} total)"
echo "────────────────────────────────────────"
echo ""

exit "${FAIL}"
