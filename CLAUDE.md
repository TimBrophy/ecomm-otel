# ecomm-otel — Demo Briefing

## Context

This project is a live demo for an enterprise e-commerce observability evaluation.
A large e-commerce group is evaluating observability platforms and has requested a 2.5-hour remote demo. The solution provider is **Elastic**.

The demo must use **our own mock data** and cover four use cases as live demos within an **80-minute window**.

---

## Claude Dev Loop

**Every implementation task must follow this sequence — no exceptions:**

1. **Run tests first** to get a baseline: `./scripts/demo.sh test`
2. **Implement** the feature or fix
3. **Run tests again** — every previously-passing test must still pass
4. **Report** what changed (test delta, not code description)

**Never report a task complete without running tests.** If tests cannot run (stack is down), say so explicitly and explain why.

**Before starting any new feature**, check current test results and cross-reference against the "Current Status" table below. Work from the top of the gap list down — don't skip ahead.

---

## Current Status (last audited 2026-06-26)

### Service readiness

| Service | Status |
|---|---|
| `storefront` | ✅ Running — Node.js + RUM SDK loaded |
| `api-gateway` | ✅ Running — OTLP instrumented |
| `product-service` | ✅ Running — Python/Flask, OTLP |
| `checkout-service` | ✅ Running — Java, PII attributes, slow_query flag wired |
| `order-service` | ✅ Running — Java, Kafka producer, OTel semantic conventions |
| `notification-service` | ✅ Running — Python, Kafka consumer |
| `feature-flag-service` | ✅ Running — slow_query flag toggle works |
| `load-generator` | ✅ Running (requires `--profile load`) |
| `mobile-app` | ❌ Missing — simulate via load-generator for demo |

### Data pipeline

| Component | Status |
|---|---|
| OTel collector → Elastic Cloud | ✅ Working |
| PII masking (card number, email) | ✅ Active in collector pipeline |
| Traces landing in ES | ✅ Confirmed (traces-generic.otel-default) |
| Logs landing in ES | ✅ Confirmed |
| Metrics landing in ES | ✅ Confirmed |

**Known auth quirk:** The managed OTLP ingest endpoint (`*.ingest.*.elastic.cloud`) rejects scoped API keys — only unrestricted keys work. `./scripts/demo.sh refresh-key` handles this automatically.

### Use case gaps (priority order)

| UC | What's missing | Priority |
|---|---|---|
| UC1 | Core Web Vitals degradation not wired to load generator; browser RUM emits no CWV metrics | High |
| UC2 | No SLOs defined; no alerting rules; no business dashboard | High |
| UC3 | `platform/` directory missing; `teams/checkout/` missing; no Kibana Terraform resources | High |
| UC4 | No ES|QL demo script; no bulk export / snapshot tooling; no migration narrative script | Medium |

---

## Test Suite

Tests live in `scripts/test.sh`. Run with:

```bash
./scripts/demo.sh test
# or directly:
./scripts/test.sh
```

Tests require the local Docker stack to be up and `.env` to have `ELASTICSEARCH_URL` and `KIBANA_URL` set.

### What the tests cover

| Test group | What it checks |
|---|---|
| Infrastructure | All 9 containers running; collector health endpoint |
| Local endpoints | storefront, api-gateway, feature-flag-service respond |
| Data pipeline | traces/logs/metrics indices non-empty; data written in last 5 min |
| UC1 — Tracing | Spans present for api-gateway, checkout-service, feature-flag-service |
| UC1 — PII masking | No unmasked card numbers or emails in stored traces |
| UC1 — Feature flag | slow_query flag present and readable |
| UC1 — Kafka | Kafka semantic convention spans present |
| UC2 — SLOs | SLOs defined in Kibana (will FAIL until UC2 built) |
| UC3 — GitOps | platform/ and teams/checkout/ directories exist (will FAIL until UC3 built) |
| UC4 — Openness | OTel semantic conventions preserved; ES\|QL query returns data |

Tests that are not yet implemented (UC2 SLOs, UC3 GitOps) will fail — that is intentional. Failing tests = open work items. The goal is to reach all-green before the demo.

---

## Operational Runbook

### Start the stack

```bash
# Start core services
docker compose up -d

# Start load generator (required for traffic)
docker compose --profile load up -d load-generator

# Verify everything
./scripts/demo.sh test
```

### Refresh a stale API key (do this if collector shows 403)

```bash
./scripts/demo.sh refresh-key
```

This resets admin credentials, mints a new unrestricted API key, writes it to `.env`, and force-recreates the collector. No Terraform needed.

### Trigger the UC1 incident scenario

```bash
./scripts/demo.sh trigger-incident
# Toggles slow_query=true for 2 min then resets
```

### Reset demo to clean baseline

```bash
./scripts/demo.sh reset
```

### MCP tool configuration (for Claude Code sessions)

The Elastic MCP Docker tool must point to this project's ES cluster:

```
server: elasticsearch
url: https://ecomm-otel-demo-b592d6.es.eu-central-1.aws.elastic.cloud
username: admin
password: <from tail -1 .elastic-credentials>
```

Run `mcp-config-set` to update if the MCP is pointing at the wrong cluster (e.g., `one-bank-*`).

---

## Demo Architecture

A realistic e-commerce application instrumented end-to-end with OpenTelemetry. One coherent story ("checkout degrades, we find the root cause") that threads through all four use cases.

### Services

| Service | Runtime | Role |
|---|---|---|
| `storefront` | Node.js | Browser RUM source, Core Web Vitals |
| `mobile-app` | EDOT mobile SDK (simulated) | iOS/Android RUM — screen load, network latency, crashes |
| `api-gateway` | Node.js / Express | Entry point, routes to backend |
| `product-service` | Python | Product catalog, AWS S3 integration |
| `checkout-service` | Java | Critical path — checkout funnel, PII data |
| `order-service` | Java | Order processing, Kafka producer |
| `notification-service` | Python | Kafka consumer, sends order confirmations |
| `feature-flag-service` | Node.js | LaunchDarkly-style flags (used as root cause trigger) |
| `load-generator` | k6 / Python | Simulates realistic traffic + injects failures |

### Infrastructure / Integrations

- **Kafka (Confluent-flavoured)** — order events between `order-service` and `notification-service`
- **AWS Lambda** (simulated or real) — async downstream task
- **GitHub webhook / deployment event** — deployment marker correlating to degradation
- **EDOT agents** — Java, Python, Node.js for backend; browser RUM SDK for storefront

### Data Pipeline

All services → **EDOT collectors** → **Elastic Cloud Serverless (Observability project)**

---

## The Four Use Cases

### UC1 — End-to-end incident investigation (the main storyline)

**Scenario:** A feature flag is toggled on `checkout-service` causing a slow DB query. Browser Core Web Vitals degrade → API gateway latency spikes → trace links to `checkout-service` → root cause is the feature flag / recent deployment.

**Must show:**
- RUM: browser (Core Web Vitals, JS error) and mobile (screen load, network latency)
- API gateway span in the trace
- Backend spans across `checkout-service`, `order-service`, Kafka producer/consumer
- PII field masking on `checkout-service` (card number, email)
- Ad-hoc ES|QL log query during investigation ("find all errors in the last 15 min for checkout")
- Ad-hoc PromQL query showing checkout latency grouped by the `realtime_fraud_detection` flag state (`checkout.latency_ms`) — same OTel metrics, no separate Prometheus server
- Distributed profiling (Universal Profiling) showing hot method in Java service
- Root cause: feature flag toggle or deployment event visible in timeline
- Autonomous investigation: an Elastic Workflow + Agent Builder agent independently investigates the same incident in the background and opens a Kibana Case with a cited RCA + remediation before the manual walkthrough finishes

### UC2 — SLOs on service maps and commercial funnels

**Scenario:** Checkout funnel SLO degrades. On-call is alerted. Business stakeholder view shows impact without technical depth.

**Must show:**
- SLO defined on checkout funnel (latency + error rate)
- Service map linking frontend → API gateway → checkout → order → Kafka
- Alert fires → routes to on-call (connector to PagerDuty or email)
- Business-readable dashboard (conversion impact, not p99 latency)
- Anomaly detection predicting breach *before* it happens

### UC3 — IaC / GitOps platform governance

**Scenario:** Central platform team ships a versioned observability bundle. A product team extends it without touching the central layer.

**Must show:**
- Kibana resources (dashboards, alerts, SLOs, RBAC, sampling rules) defined as code (Terraform or saved objects in Git)
- `platform/` layer — canonical templates checked into Git, deployed via CI
- `teams/checkout/` layer — team-specific additions that inherit without overwriting
- No drift: a `terraform plan` shows zero changes to central layer after team additions

### UC4 — Openness, data access, vendor independence

**Scenario:** Prove the commitment to open standards is structural.

**Must show:**
- OTel data model and semantic conventions preserved natively in Elasticsearch (not converted to proprietary schema) — show a raw document in Dev Tools
- ES|QL / REST API access to raw telemetry (logs, traces, metrics, configs) — not just UI
- API access to dashboards, SLOs, RBAC configs (Kibana saved objects API)
- Bulk export story at scale — ILM, data tiers, cost model for 25–30 TB/day
- Migration story: "if you leave, your data and configs are already in open formats — here's what export looks like"
- **Known gap to address honestly:** Grafana-compatible JSON and OpenSLO are not natively supported; position API-first access + open formats as the equivalent answer

---

## Key Elastic Differentiators to Highlight

1. **Native OTel storage** — semantic conventions preserved, not mapped to proprietary schema
2. **ES|QL** — flexible ad-hoc queries over logs/traces/metrics in one language, live in the demo
3. **Universal Profiling** — continuous distributed profiling, no code changes
4. **Single platform** — logs, traces, metrics, RUM, profiling in one correlated view (no context switching)
5. **Kibana-as-code** — Terraform provider + saved objects API = real GitOps story
6. **EDOT** — Elastic Distribution of OTel; official, supported, upstream-compatible
7. **Agentic investigation** — Workflows + Agent Builder turn an alert into a fully-investigated Case, grounded in your own runbooks, before a human opens a tab

---

## Watch Points / Prep Notes

| Area | Risk | Mitigation |
|---|---|---|
| Mobile RUM | EDOT mobile SDKs are newer — verify GA vs beta status | Use simulated mobile traffic via load generator if needed; be transparent |
| OpenSLO / Grafana JSON | Evaluators may raise these explicitly; Elastic doesn't support natively | Pivot to "API-first config access" — show saved objects API exports configs as JSON that lives in Git |
| PII / GDPR | `checkout-service` handles card data, email | PII masking is handled by an Elasticsearch ingest pipeline (`pii-masking`) — not the collector. Define it in `platform/ingest-pipelines/`. |
| Kafka monitoring | Confluent may be called out explicitly | Instrument `order-service` producer and `notification-service` consumer with OTel Kafka semantic conventions |
| Migration question | "What if we leave?" | Be confident: data is in Elasticsearch open format, ES|QL queryable, bulk export via snapshot API or data stream export |
| 25–30 TB/day cost model | Commercial question in UC4 | Prepare ILM tier diagram + rough cost model with AE/commercial team before the session |
| Ingest API key | Managed OTLP endpoint rejects scoped keys | Always use unrestricted keys — `provision_ingest_key` in demo.sh is fixed for this |

---

## Time Budget (80 minutes for all four UCs)

| Use Case | Target |
|---|---|
| UC1 — E2E investigation | 25 min |
| UC2 — SLOs + funnels | 20 min |
| UC3 — IaC/GitOps | 20 min |
| UC4 — Openness | 15 min |

---

## Project Structure

```
ecomm-otel/
├── CLAUDE.md                  # this file — briefing + dev loop + current status
├── scripts/
│   ├── demo.sh                # main CLI: apply/destroy/refresh-key/test/trigger-incident/reset
│   └── test.sh                # smoke test suite (run before/after every change)
├── services/
│   ├── storefront/            # Node.js, browser RUM
│   ├── api-gateway/           # Node.js
│   ├── product-service/       # Python
│   ├── checkout-service/      # Java
│   ├── order-service/         # Java
│   ├── notification-service/  # Python
│   └── feature-flag-service/  # Node.js
├── load-generator/            # Python load script
├── collector/                 # EDOT collector config
├── platform/                  # IaC — central observability bundle (TO BUILD)
│   ├── dashboards/
│   ├── alerts/
│   ├── slos/
│   ├── rbac/
│   ├── runbooks/              # SRE playbooks (sre-runbooks index, semantic search)
│   ├── agent-tools/           # Agent Builder custom tools
│   ├── agents/                # Agent Builder agents (autonomous-SRE)
│   └── workflows/             # Elastic Workflows (RCA + Case automation)
├── teams/
│   └── checkout/              # team-layer extensions (TO BUILD)
├── infra/
│   ├── elastic/               # Terraform: EC serverless project
│   └── aws/                   # Terraform: ECS, ALB, MSK, Lambda
└── docker-compose.yml
```

---

## Customer Context

- Large e-commerce group operating across multiple brands and regions
- Scale: 25–30 TB/day telemetry ingestion target
- Multi-cloud: AWS + GCP + Confluent
- Emphasis on vendor independence — likely sensitive to lock-in
- PII sensitivity is real — GDPR context, not theoretical
- Technically sophisticated evaluation team
