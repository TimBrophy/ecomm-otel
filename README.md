# ecomm-otel

A realistic e-commerce application instrumented end-to-end with OpenTelemetry, built to demonstrate Elastic Observability across four use cases.

## Architecture

```
Browser / Mobile
      │
      ▼
 storefront (Node.js + RUM)
      │
      ▼
 api-gateway (Node.js)
      │
      ├──▶ product-service (Python)
      │
      └──▶ checkout-service (Java)
                │
                ▼
          order-service (Java)
                │
                ├──▶ Kafka (order-events)
                │         │
                │         ▼
                │   notification-service (Python)
                │
                └──▶ feature-flag-service (Node.js) ◀── polled every 5s

EC2 profiling host (Elastic Agent 9.4.3 + OTel profiling integration)
```

All services export traces, logs, and metrics via OTLP to an **EDOT collector**, which forwards to **Elastic Cloud Serverless**.

---

## Quick Start

### Prerequisites

- Docker + Docker Compose
- Terraform ≥ 1.5
- AWS CLI + credentials with EC2/IAM rights (for profiling host)
- An Elastic Cloud API key with project creation rights

### 1. Configure `.env`

Copy `.env.example` to `.env` and fill in the required values:

```bash
# Required
EC_API_KEY=<your Elastic Cloud API key>
AWS_ACCESS_KEY_ID=<your AWS key>
AWS_SECRET_ACCESS_KEY=<your AWS secret>

# Optional — wires Slack notifications to alert rules
# SLACK_TOKEN=xoxb-your-bot-token
# SLACK_CHANNEL_ID=your-slack-channel-id
# SLACK_CHANNEL_NAME=#ecomm-alerts
```

All endpoint vars (`ELASTICSEARCH_URL`, `KIBANA_URL`, `FLEET_URL`, etc.) are written automatically by `build`.

### 2. Build the full stack

```bash
./scripts/demo.sh build
```

This is the only command you need to run. It does everything in order:

| Phase | Step | What happens |
|---|---|---|
| 1 | Terraform apply (pass 1) | Creates Elastic Cloud Serverless Observability project |
| 1 | Credential provisioning | Resets admin creds, mints unrestricted ingest API key, writes to `.env` |
| 1 | Ingest pipelines | Deploys PII masking pipeline (`pii-masking`) |
| 1 | Kibana spaces + RBAC | Creates `product-team` space and `product-team-viewer` role |
| 1 | Terraform apply (pass 2) | Deploys Kibana resources + Slack connector (if configured) |
| 1 | Docker Compose | Starts all 9 services + load generator |
| 1 | SLOs | Deploys 4 SLOs (checkout latency, error rate, API gateway availability, order fulfilment rate) |
| 1 | Alert rules | Deploys 4 alert rules wired to Slack connector if present |
| 1 | Knowledge base | Indexes SRE runbooks into `sre-runbooks` for semantic search |
| 1 | Agent Builder | Deploys `ecomm-sre-rca` agent and `search_runbooks` tool |
| 1 | Workflows | Deploys the autonomous RCA incident-response workflow |
| 1 | Product team project | Creates the product-team Serverless project, links it via Cross-Project Search, deploys the Checkout Business Overview dashboard |
| 2 | Fleet policy | Creates Fleet agent policy + system integration via Kibana API |
| 2 | EC2 instance | Launches Amazon Linux 2023 with Elastic Agent 9.4.3 enrolled to Fleet |

### 3. Manual step — APM Anomaly Detection (optional, UC2)

Navigate to **APM > Settings > Anomaly detection** → create jobs for `checkout-service` and `api-gateway`.

The ML anomaly jobs API is restricted in Serverless — this is a one-time UI step. Reference configs are in `platform/ml-jobs/`.

### 4. Verify

```bash
./scripts/demo.sh test
```

Target: all tests green before the demo. Known expected failures until the manual step above: ML health badges won't appear on the service map.

---

## Demo Controls

```bash
# Trigger the UC1 incident — enables realtime_fraud_detection flag
# Injects: +400–900ms checkout latency, 8% timeout errors, Kafka backpressure
./scripts/demo.sh trigger-incident

# Reset all feature flags to clean baseline
./scripts/demo.sh reset

# Fix a stale API key (collector returning 403)
./scripts/demo.sh refresh-key
```

> `trigger-incident` stays active until you run `reset`. This is intentional — it lets SLO burn rates accumulate visibly during the UC2 demo segment.

---

## Teardown

```bash
./scripts/demo.sh teardown
```

Single confirmation, destroys everything in the right order: AWS first (while credentials are still in `.env`), then Elastic Cloud + Docker.

---

## All Commands

| Command | Description |
|---|---|
| `build` | **Full stack up** — Elastic Cloud + Docker + AWS profiling host |
| `teardown` | **Full stack down** — one confirmation, correct order |
| `apply` | Elastic Cloud + Docker only (no AWS) |
| `destroy` | Elastic Cloud + Docker only |
| `apply-aws` | Fleet policy + EC2 profiling host (requires `apply` first) |
| `destroy-aws` | Destroy EC2 profiling host only |
| `test` | Smoke tests against local stack + Elastic Cloud |
| `trigger-incident` | Enable `realtime_fraud_detection` flag (cascading failures) |
| `reset` | Reset feature flags to clean baseline |
| `refresh-key` | Mint fresh ingest API key + restart collector |
| `provision-slos` | Re-deploy SLOs to Kibana |
| `provision-knowledge-base` | Re-index SRE runbook/playbook docs into `sre-runbooks` |
| `provision-agent-builder` | Re-deploy Agent Builder tools + the autonomous-SRE agent |
| `provision-workflows` | Re-deploy the autonomous RCA workflow |
| `provision-alerts` | Re-deploy alert rules to Kibana |
| `provision-spaces` | Re-deploy Kibana spaces |
| `provision-rbac` | Re-deploy Kibana RBAC roles |
| `provision-product-team` | Create/update the product-team Serverless project, configure Cross-Project Search, deploy the Checkout Business Overview dashboard |
| `provision-team` | Push team layer to `product-team` space: checkout funnel + Business Overview (9 Lens panels) |
| `provision-fleet` | Re-create Fleet agent policy + system integration |
| `provision-ml` | Print ML job reference configs (UI-only in Serverless) |
| `plan` | `terraform plan` for `infra/elastic` |
| `init` | `terraform init` for `infra/elastic` |

---

## Services

| Service | Runtime | Port | Role |
|---|---|---|---|
| `storefront` | Node.js | 3000 | Browser RUM, Core Web Vitals |
| `api-gateway` | Node.js | 8080 | Entry point, routes to backends |
| `product-service` | Python | 8081 | Product catalogue |
| `checkout-service` | Java | 8082 | Checkout funnel, PII attributes, fraud detection flag |
| `order-service` | Java | 8083 | Order processing, Kafka producer, backpressure simulation |
| `notification-service` | Python | — | Kafka consumer, order confirmations |
| `feature-flag-service` | Node.js | 8090 | Feature flag toggle (`realtime_fraud_detection`) |
| `load-generator` | Python | — | Simulates realistic traffic (opt-in profile) |

---

## The Incident Scenario (UC1)

The `realtime_fraud_detection` flag simulates a compliance feature that was rushed to production. When enabled via `trigger-incident`:

| Layer | What breaks | Signal in Elastic |
|---|---|---|
| `checkout-service` | Synchronous fraud API call adds 400–900ms + 8% timeouts. The call also holds one of only 3 concurrent connections in FraudShield's client SDK pool — under concurrent load, requests queue for a slot, pushing latency past 900ms | `fraud_check` child span with `peer.service=fraud-shield-api`; timeout errors as span exceptions; pool saturation visible via `fraud_check.pool.active_connections` / `fraud_check.pool.queued_requests`; end-to-end impact visible via `checkout.latency_ms` grouped by flag state (all PromQL-queryable) |
| `order-service` | Downstream backpressure from slower checkouts | `order.processing_delayed=true` span attribute; structured log `fraud_detection_backpressure=true` |
| Kafka | Producer lag grows as order-service slows | Kafka semantic convention spans show increasing offsets |

Root cause is revealed by the `feature_flag.realtime_fraud_detection: true` attribute propagated through the trace.

---

## The Four Use Cases

### UC1 — End-to-end incident investigation (25 min)
Checkout degrades → trace waterfall reveals `fraud_check` span → feature flag attribute is the smoking gun. Demonstrates RUM, distributed tracing, Kafka pipeline tracing, PII masking, and ES|QL ad-hoc investigation.

### UC2 — SLOs on service maps and commercial funnels (20 min)
Four pre-provisioned SLOs degrade when the incident fires. On-call is alerted via Slack. The **Checkout Business Overview** dashboard (in the `product-team` space) shows conversion impact, throughput, latency trends, and fraud detection flag impact — no p99 jargon. Anomaly detection predicts breach before it happens.

### UC3 — IaC / GitOps platform governance (20 min)
Central platform layer (`platform/`) + team layer (`teams/checkout/`) deployed entirely as code. `terraform plan` shows zero drift. All Kibana resources — dashboards, alerts, SLOs, RBAC — live in Git.

### UC4 — Openness and vendor independence (15 min)
OTel semantic conventions preserved natively in Elasticsearch. ES|QL provides direct API access across logs, traces, and metrics. Bulk export and migration paths demonstrated live.

---

## Data Pipeline

```
Services (EDOT agents: Java, Python, Node.js)
    │  OTLP/gRPC (port 4317)
    ▼
EDOT Collector (standalone)
    │  OTLP/HTTP → Elastic Cloud mOTLP endpoint
    ▼
Elastic Cloud Serverless
    ├── traces-generic.otel-default
    ├── logs-generic.otel-default  
    └── metrics-generic.otel-default
```

**PII masking** is applied by an Elasticsearch ingest pipeline (`pii-masking`) — card numbers and email addresses in checkout spans are masked before indexing.

**Known auth quirk:** The managed OTLP ingest endpoint rejects scoped API keys. `build` always mints an unrestricted key. If the collector starts returning 403, run `./scripts/demo.sh refresh-key`.

---

## Infrastructure

| Layer | Tool | Location |
|---|---|---|
| Local dev | Docker Compose | `docker-compose.yml` |
| Elastic Cloud (Serverless) | Terraform + Kibana API | `infra/elastic/` |
| AWS EC2 (profiling host) | Terraform | `infra/aws/` |

The EC2 instance runs Amazon Linux 2023 (BTF kernel support for eBPF profiling) with Elastic Agent 9.4.3. It is tagged with the required Elastic SA AWS org policy tags (`division`, `org`, `team`, `project`, `keep-until`) and uses an IAM SSM instance profile — no SSH key required.

To shell into the profiling host for debugging:
```bash
source .env && aws ssm start-session \
  --target $(cd infra/aws && terraform output -raw profiling_host_instance_id) \
  --region eu-central-1
```

---

## Test Suite

```bash
./scripts/demo.sh test
```

Covers: all 9 containers, collector health, data pipeline, UC1 tracing, PII masking, `realtime_fraud_detection` flag, Kafka spans, SLOs + alerts (UC2), GitOps structure + CPS (UC3), OTel native storage (UC4), knowledge base + agent builder + workflow (UC5).

Failing tests = open work items. Target is all-green before the demo.
