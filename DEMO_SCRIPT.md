# Demo Script — Elastic Observability

**Duration:** 80 minutes across four use cases  
**Format:** Live remote demo (Microsoft Teams)  
**Audience:** Technically sophisticated evaluation team  
**Stack:** `./scripts/demo.sh apply` — all services running locally, data in Elastic Cloud Serverless

---

## Pre-Flight Checklist (15 min before)

```bash
# 1. Confirm all containers are up
docker compose ps

# 2. Run smoke tests — must be 30/30 before you start
./scripts/demo.sh test

# 3. Confirm data is fresh (last 5 min)
# Check: Kibana > Discover > traces-* — should show recent spans

# 4. Reset demo flags to clean baseline
./scripts/demo.sh reset

# 5. Open these tabs in advance:
#   - Kibana > Observability > APM > Services
#   - Kibana > Observability > SLOs
#   - Kibana > Observability > Infrastructure > Hosts
#   - Kibana > Spaces > product-team > Dashboards > "Checkout Business Overview"
#   - Kibana > Discover (metrics-* data view)
#   - Dev Tools (for ES|QL)
```

**If collector shows 403:** `./scripts/demo.sh refresh-key` — takes ~60s.

---

## Opening (2 min)

> "What I'm going to show you today is a real e-commerce stack — not a sandbox with fake data. 
> Seven services, Kafka in the middle, a Java checkout path, Node.js frontend, Python catalog. 
> All instrumented with OpenTelemetry. All data flowing to Elastic Cloud Serverless.
>
> We're going to walk through a realistic incident, show you how SLOs connect to business impact, 
> show you how a platform team governs observability at scale with code, and then prove that 
> you're never locked in — your data stays yours, in open formats, queryable with standard APIs."

---

## UC1 — End-to-End Incident Investigation (25 min)

### 1.1 Set the scene (2 min)

> "It's 2am. Your checkout funnel starts degrading. How quickly can you find the root cause?"

Show: **APM > Services** — point out all seven services in the list.

> "Every service is instrumented — from the browser frontend through API gateway, 
> into the Java checkout and order services, across Kafka, and into the notification consumer.
> One continuous trace, no gaps."

### 1.2 Trigger the incident (1 min)

Run in terminal (keep it visible — it's a good demo moment):

```bash
./scripts/demo.sh trigger-incident
```

> "I'm enabling a feature flag — `realtime_fraud_detection=true`. This was shipped 
> last sprint as a compliance requirement — synchronous fraud checking on every checkout. 
> It looked fine in staging. Let's see what it does under load."

The incident stays active until you run `./scripts/demo.sh reset`. Move on — let latency build.

### 1.3 Show the service map (3 min)

Navigate: **APM > Service Map**

> "Here's the topology Elastic has automatically built from trace data — no manual config, 
> no topology file. Every service, every dependency."

Point out:
- `storefront` → `api-gateway` → `checkout-service` → `order-service` → Kafka → `notification-service`
- `checkout-service` → `feature-flag-service` (the flag poll)

> "Health indicators on the service map are powered by APM anomaly detection — ML jobs 
> that learn each service's baseline. These need to be enabled once in 
> **APM > Settings > Anomaly detection**, then Kibana does the rest."

*Note: anomaly detection health badges require ML jobs to be created via the APM Settings UI (one-time setup). The API for ML anomaly jobs is restricted in Serverless — this is a UI-only step before the demo.*

### 1.4 Drill into the trace (5 min)

Navigate: **APM > Services > checkout-service > Transactions > POST /checkout**

> "Latency is spiking on the checkout path. Let me find a slow trace."

Click a high-latency trace. Show the waterfall.

> "Here's the full distributed trace — from the API gateway span all the way through 
> checkout, into order-service, and across Kafka to the notification consumer. 
> One view, zero context switching."

Point out:
- A new child span `fraud_check` appearing at the end of every checkout span — this is the smoking gun
- `fraud_check.provider: FraudShield`, `fraud_check.duration_ms: 650`, `peer.service: fraud-shield-api`
- On ~8% of traces: `fraud_check.result: timeout` with a `FraudCheckTimeoutException` error recorded on the span
- The cascade: checkout slow → order-service span shows `order.processing_delayed: true` → Kafka producer lag grows
- Kafka producer span in order-service → Kafka consumer span in notification-service

> "The feature flag attribute `feature_flag.realtime_fraud_detection: true` is propagated 
> through the trace. We can see the exact moment it was enabled and every request it touched. 
> The fraud check is a synchronous call to an external API — it's adding 600ms to every checkout 
> and timing out on nearly 1 in 10 transactions."

### 1.5 Confirm with ES|QL (5 min)

Navigate: **Discover** → switch to **ES|QL** mode (toggle top-left).

> "Now I'll show you something the APM UI can't do — ad-hoc query directly over the raw data."

Paste and run — **fraud check spans with root cause signal:**

```esql
FROM traces-*
| WHERE @timestamp > NOW() - 15 minutes
| WHERE resource.attributes.service.name == "checkout-service"
| WHERE name == "fraud_check"
| EVAL duration_ms = duration / 1000000
| KEEP @timestamp, name, duration_ms, `attributes.fraud_check.provider`, `attributes.fraud_check.result`, trace_id, span_id
| SORT duration_ms DESC
| LIMIT 20
```

> "Every fraud check span is here — provider, result, exact duration. I can see the timeouts 
> alongside the slow approvals. This is the ES|QL story: one query over raw trace data, 
> no pre-built dashboard needed."

Paste and run — **count of timeouts vs approvals in the last 15 minutes:**

```esql
FROM traces-*
| WHERE @timestamp > NOW() - 15 minutes
| WHERE name == "fraud_check"
| STATS count = COUNT(*) BY `attributes.fraud_check.result`
```

Paste and run — **p99 latency across all services:**

```esql
FROM traces-*
| WHERE @timestamp > NOW() - 5 minutes
| WHERE kind == "Server"
| STATS avg_ms = AVG(duration) / 1000000,
        p99_ms = PERCENTILE(duration, 99) / 1000000,
        count = COUNT(*)
  BY resource.attributes.service.name
| SORT p99_ms DESC
```

> "P99 latency ranked across every service. ES|QL — the same language I'd use for 
> logs, metrics, traces. One query language for everything."

Paste and run — **error rate by service (blast radius):**

```esql
FROM traces-*
| WHERE @timestamp > NOW() - 15 minutes
| WHERE kind == "Server"
| EVAL is_error = CASE(
    `attributes.http.response.status_code` >= 400, 1,
    `attributes.event.outcome` == "failure", 1,
    0)
| STATS total = COUNT(*), errors = SUM(is_error)
  BY resource.attributes.service.name
| EVAL error_rate_pct = ROUND(errors * 100.0 / total, 1)
| SORT error_rate_pct DESC
```

> "Blast radius — which services have elevated error rates right now."

**Latency distribution** — navigate to: **APM > Services > checkout-service > Metrics**

> "The Metrics tab shows JVM internals — heap, GC pauses, thread counts — from the 
> Java OTel agent. No code changes, no profiling agents to install."

**Bonus — if your team already lives in PromQL:** switch back to **Discover** → ES|QL mode.

> "Some of you already have a library of PromQL queries and Grafana dashboards. You don't 
> have to throw those away — Elasticsearch speaks PromQL natively over the same OTel data, 
> no separate Prometheus server to run."

Paste and run — **checkout latency, grouped by the feature flag that's causing it:**

```esql
PROMQL index=metrics-generic.otel-default step=1s checkout_latency_ms=(avg by (attributes.feature_flag.realtime_fraud_detection) (metrics.checkout.latency_ms))
| WHERE step > NOW() - 15 minutes
| SORT step ASC
```

> "Two lines, split by the exact flag we just toggled. Flag off: 5–10ms, checkout is 
> instant. Flag on: 800ms to over a second — the fraud check's own 400–900ms, plus 
> queueing behind FraudShield's 3-connection pool limit stacking on top. Same underlying 
> OTel metric data as everything else in this stack — just PromQL syntax, grouped by 
> label, exactly like your Grafana dashboards do today."

### 1.6 Kafka visibility (3 min)

Navigate: **Discover** → ES|QL mode. Paste and run:

```esql
FROM traces-*
| WHERE @timestamp > NOW() - 15 minutes
| WHERE kind IN ("Producer", "Consumer")
| KEEP @timestamp, resource.attributes.service.name, name, duration, `attributes.messaging.kafka.message.offset`, trace_id
| SORT @timestamp DESC
| LIMIT 50
```

> "One question evaluators always ask: can you see inside Kafka? 
> Yes — we trace the producer span in order-service and the consumer span in 
> notification-service as first-class OTel spans, with Kafka semantic conventions: 
> `messaging.system=kafka`, topic, partition, consumer group."

Show the Kafka spans — producer and consumer linked by `trace_id`.

### 1.7 Root cause summary (2 min)

> "Total time to root cause: minutes, not hours. We went from 'checkout is slow' to 
> 'realtime_fraud_detection flag enabled at 14:32, synchronous FraudShield API call 
> adding 650ms per checkout, timing out 8% of transactions — cascading into order-service 
> and Kafka lag — confirmed by distributed trace and live ES|QL query, without leaving Elastic.
>
> PII handling note: card numbers and email addresses in checkout spans are masked 
> at the service level before they reach the collector. That's a GDPR guarantee, 
> not a process — the field never hits the wire unmasked."

---

## UC2 — SLOs on Service Maps and Commercial Funnels (20 min)

### 2.1 Show the SLOs (5 min)

Navigate: **Observability > SLOs**

Three SLOs are pre-provisioned:
- **Checkout Service — P99 Latency** (target: 95% of requests under 500ms)
- **Checkout Service — Error Rate** (target: 99% success rate)
- **API Gateway — Availability** (target: 99.9% uptime)

> "These aren't dashboards someone built by hand. They're defined in code, checked 
> into Git, and deployed with a single script. Every time we spin up this stack, 
> the SLOs are recreated automatically."

Click into **Checkout Service — P99 Latency**:

> "You can see the burn rate, the error budget remaining, and the trend. During the 
> incident we just triggered, this SLO would have started burning. That's your 
> on-call signal."

### 2.2 Alerting (3 min)

Navigate: **Observability > Alerts**

Three alert rules fire during the incident scenario:

| Rule | Condition | Type |
|---|---|---|
| Checkout — Latency Spike | p99 span duration > 1s over 5 min | ES\|QL query |
| Checkout — Error Spike | > 5 error spans over 5 min | ES\|QL query |
| Checkout Latency SLO — Fast Burn Rate | burning error budget 14.4× fast (critical) or 6× (high) | SLO burn rate |

> "Three layers of alerting, all pointing at the same event. The ES|QL rules fire 
> within a minute of the incident — immediate signal. The SLO burn rate rule fires 
> when the budget depletion rate crosses a threshold — that's the on-call escalation. 
> They're not separate systems: both use the same underlying trace data."

> "These route to whatever you have — PagerDuty, Slack, email, OpsGenie. 
> Connectors are configured once and referenced by any rule."

**To trigger the alert live during the demo:**

```bash
./scripts/demo.sh trigger-incident
```

Then navigate to **Observability > Alerts** — latency and error rules will fire within 1–2 minutes.

Click an alert → **View in context** → lands in APM traces filtered to checkout-service.

### 2.3 Service Map + SLO correlation (4 min)

Navigate: **APM > Service Map**

> "SLO status overlays directly on the service map. When checkout's error budget 
> starts burning, the node turns amber. Your on-call engineer can see in seconds 
> which service is the problem and how far the blast radius extends."

### 2.4 Business view (5 min)

Navigate: **Kibana > Spaces > product-team > Dashboards > Checkout Business Overview**

> "This is the business stakeholder view — deployed as code from our Git repo. 
> Four KPI tiles across the top: total checkouts, average checkout time in milliseconds, 
> orders fulfilled, and P95 latency. No p99 jargon. 
> A non-technical stakeholder can read this at a glance."

Point out:
- Row 1: KPI tiles — Checkouts, Avg Checkout Time (ms), Orders Fulfilled, P95 Latency (ms)
- Row 2: **Checkout Throughput** (5-min buckets time series) and **Checkout Latency Over Time** (avg + p95 on same chart)
- Row 3: **Fraud Detection: Latency by Flag State** (bar chart — immediately shows the flag impact side-by-side), **Request Volume by Service** (horizontal bar — breadth of the funnel)

> "During the incident, the Fraud Detection panel tells the story without a trace waterfall: 
> latency is split by flag state — `true` vs `false`. The business stakeholder sees 
> 'flag on = slow' in one bar chart. Same underlying trace data as the engineering view, 
> different lens."

> "This dashboard is defined in `teams/checkout/dashboards/business-overview.py`, 
> checked into Git, and deployed with `provision-team`. It's not a screenshot — 
> it's live ES|QL running against the same `traces-generic.otel-default` index."

### 2.5 Anomaly detection (3 min)

Navigate: **APM > Settings > Anomaly detection** — show the ML job configuration UI.

> "Beyond threshold alerts, Elastic runs ML anomaly detection on the transaction latency 
> and throughput streams. It learns each service's normal pattern — including time-of-day 
> and day-of-week — and surfaces anomalies before they breach the SLO.
>
> For a 25–30 TB/day environment, this is the difference between reactive and predictive."

*Setup note: ML jobs for APM anomaly detection must be created via APM > Settings > Anomaly detection in Kibana. The ML Jobs API is restricted in Serverless — this is a one-time UI step. Once created, jobs run continuously and feed health indicators back to the service map.*

---

## UC3 — IaC / GitOps Platform Governance (20 min)

### 3.1 The problem statement (2 min)

> "At 25 TB/day, multiple teams, multiple clouds — observability 
> configuration becomes infrastructure. If dashboards and alerts live only in Kibana, 
> you get drift: teams fork things, the central standard erodes, new projects start 
> from scratch.
>
> Our answer is Kibana-as-code. Two layers: a platform layer the central team owns, 
> and a team layer each product team owns. Neither touches the other."

### 3.2 Show the two-layer structure (3 min)

Share your terminal or editor:

```
platform/                  ← central platform team owns this
├── spaces/
│   └── product-team.json  ← which Kibana spaces exist
├── rbac/
│   └── product-team-viewer.json  ← who can see what
├── slos/
│   ├── checkout-latency.json
│   ├── checkout-errors.json
│   └── api-gateway-availability.json
├── alerts/                ← alert rules (ES|QL + SLO burn rate)
├── ingest-pipelines/      ← field masking, enrichment
└── ml-jobs/               ← anomaly detection reference configs

teams/
└── checkout/              ← checkout team owns this
    └── dashboards/
        ├── checkout-funnel.ndjson   ← funnel overview (markdown + links)
        └── business-overview.py     ← live Lens dashboard (8 panels + KPIs)
```

> "Two layers. The platform team controls access topology — which spaces exist, 
> who can see what data, what SLOs are enforced. The checkout team controls their 
> content — dashboards, saved views — without ever touching the platform layer."

### 3.3 Platform layer: show the SLO as code (2 min)

Open `platform/slos/checkout-latency.json`:

> "The SLO you saw in UC2 is exactly this file. The source of truth is Git. 
> If someone deletes it in Kibana, the next deploy restores it. 
> If someone edits the target in Kibana, the next deploy corrects it back."

### 3.4 Platform layer: spaces and RBAC as code (3 min)

Open `platform/spaces/product-team.json`:

> "The platform team defines which Kibana spaces exist. The checkout team gets 
> a space — but they didn't create it and they can't remove it. 
> That's a platform decision, not a team decision."

Open `platform/rbac/product-team-viewer.json`:

> "And here's what that team can see: read access to traces, logs, and metrics. 
> Dashboard and Discover access in their space only. Defined in code, reviewed in Git, 
> deployed centrally. No ClickOps, no 'can you give me access to X' tickets."

Deploy both live:

```bash
./scripts/demo.sh provision-spaces
./scripts/demo.sh provision-rbac
```

> "Idempotent. If the space already exists, it's updated in place. 
> If a role drifts, it's corrected. In CI this runs on every merge to main."

### 3.5 Team layer: push the dashboard as code (5 min)

> "Now I'm the checkout team. The platform team gave me a space and a role. 
> I own what goes into that space."

Open `teams/checkout/dashboards/checkout-funnel.ndjson` in editor:

> "My dashboard is a file. It's in Git. It went through code review. 
> When I'm ready to ship it, I run one command."

Run live in terminal:

```bash
./scripts/demo.sh provision-team
```

Expected output:
```
→ Provisioning team layer: checkout → space: product-team
  ✓ checkout-funnel (2 object(s))
  ✓ Checkout Business Overview (9 object(s))
    https://<your-kibana>/s/product-team/app/dashboards#/view/checkout-business-overview
```

Navigate to the URL it prints. Show both dashboards in the `product-team` space — 
the **Checkout Funnel** overview and the **Checkout Business Overview** live data dashboard.

> "Two dashboards, two files, one command. The checkout team shipped both through the same 
> GitOps pipeline. The platform layer is untouched — the space, role, and SLOs 
> the platform team provisioned are exactly as they were."

Switch the Kibana space switcher between default and product-team to show the isolation.

### 3.6 Sampling and collector config (2 min)

> "At 25–30 TB/day you need tail-based sampling. The collector config — 
> including sampling rules — is also in Git. When the checkout team needs 
> higher fidelity on their critical path, they submit a PR. 
> The platform team reviews. It deploys."

Show `collector/otel-collector.yaml` briefly — point out the pipeline structure.

> "The collector pipeline is code. The Fleet agent policy — which governs host metrics 
> collection on the collector host — is also code, provisioned by the same deploy script. 
> Every layer of the observability stack: collector config, agent policies, 
> Kibana spaces, roles, SLOs, dashboards. Nothing lives only in a UI."

---

## UC4 — Openness, Data Access, Vendor Independence (15 min)

### 4.1 Raw document in Dev Tools (3 min)

Navigate: **Dev Tools**

```
GET /traces-generic.otel-default/_search
{
  "size": 1,
  "query": {
    "term": {"resource.attributes.service.name": "checkout-service"}
  },
  "sort": [{"@timestamp": "desc"}]
}
```

> "This is a raw OTel span as stored in Elasticsearch. Look at the field names: 
> `resource.attributes.service.name`, `attributes.http.response.status_code`, 
> `attributes.messaging.system`. These are the OTel semantic conventions, 
> preserved natively — not mapped to a proprietary schema.
>
> If you move to a different backend tomorrow, the data model is already 
> in an open standard. Your instrumentation doesn't change."

### 4.2 ES|QL access (4 min)

Navigate: **Discover** — run ad-hoc queries:

```esql
FROM traces-*
| WHERE @timestamp > NOW() - 5 minutes
| WHERE kind IN ("Producer", "Consumer")
| KEEP @timestamp, resource.attributes.service.name, name, duration, `attributes.messaging.kafka.message.offset`, trace_id
| SORT @timestamp DESC
| LIMIT 20
```

> "ES|QL works directly over the raw telemetry. No pre-aggregation required, 
> no separate query language for logs vs traces vs metrics. One language, 
> one dataset, all signals."

```esql
FROM metrics-*
| WHERE @timestamp > NOW() - 5 minutes
| WHERE `metrics.jvm.memory.used` IS NOT NULL
| STATS avg_heap_mb = AVG(`metrics.jvm.memory.used`) / 1048576 
    BY resource.attributes.service.name
| SORT avg_heap_mb DESC
```

> "Same query language over metrics. JVM heap by service, live."

### 4.3 API access to configs (3 min)

In terminal:

```bash
source .env
# Export SLO config via API
curl -s "${KIBANA_URL}/api/observability/slos?size=100" \
  -H "Authorization: ApiKey ${ELASTIC_INGEST_API_KEY}" | python3 -m json.tool | head -40
```

> "Every Kibana configuration — SLOs, dashboards, alerts, RBAC rules — is accessible 
> via REST API. This is how our GitOps tooling works. It's also how you'd migrate: 
> export via API, check into Git, import to a new system."

### 4.4 The migration question (3 min)

> "You asked: what if we leave?
>
> Your telemetry data is in Elasticsearch, in open OTel format. You can query it 
> with standard ES|QL or the REST API. You can snapshot it with the Elasticsearch 
> snapshot API — same open format, portable to S3 or GCS.
>
> Your configuration is in Git. SLOs, dashboards, alerts — all in JSON via the 
> Kibana saved objects API.
>
> We don't natively export Grafana JSON or OpenSLO YAML. I'll be direct about that. 
> What we do instead: your configs are in Git-managed JSON that's already version 
> controlled, API-accessible, and in formats documented in open specs. 
> The migration story is code, not screenshots."

### 4.5 Scale and cost model (2 min)

> "At 25–30 TB/day:
> - Hot tier: 7 days (active queries, SLO evaluation)
> - Warm tier: 30 days (incident investigation, trend analysis)  
> - Cold/frozen tier: 12+ months (compliance, audit)
>
> Frozen tier costs are a fraction of hot — your 25 TB/day retention is not 
> 25 TB/day at hot-tier pricing for 12 months. The ILM policy manages this 
> automatically, and the data remains queryable via ES|QL at frozen tier."

---

## Handling Tough Questions

| Question | Answer |
|---|---|
| "Does this support Grafana dashboards?" | "Not natively. Our answer is Kibana-as-code — dashboards in Git, deployed via API, same openness. The Kibana saved objects API is well-documented and stable." |
| "What about OpenSLO?" | "We don't parse OpenSLO YAML today. Our SLO config format is JSON, Git-managed, API-deployed — the openness principle is there, the specific format isn't OpenSLO yet." |
| "Can we bring our own collectors?" | "Yes — any OTel-compatible collector works. We ship EDOT (our supported distribution) but the endpoint accepts standard OTLP from any collector, including Grafana Alloy or the upstream collector." |
| "What about multi-cloud?" | "The collector runs anywhere — ECS, GKE, on-prem. It forwards to a single Elastic Cloud endpoint. You get a unified view across all your environments." |
| "Universal Profiling?" | "Continuous profiling, zero code changes, correlates with traces. Available in Elastic Cloud. I can show you the profiling view if you want to go deeper." |
| "Cost at 25 TB/day?" | "Bring your AE — this needs a proper sizing conversation. Rough order: hot retention is the expensive tier, ILM to warm/frozen dramatically reduces cost for aged data. I can set up a technical sizing call." |

---

## Demo Controls

```bash
# Trigger incident (realtime_fraud_detection on — stays active until reset)
./scripts/demo.sh trigger-incident

# Reset everything to clean state
./scripts/demo.sh reset

# Redeploy SLOs if they drift
./scripts/demo.sh provision-slos

# Redeploy alert rules
./scripts/demo.sh provision-alerts

# Reprovision Fleet agent policy + enrollment token
./scripts/demo.sh provision-fleet

# Fix 403 on collector
./scripts/demo.sh refresh-key

# Full smoke test
./scripts/demo.sh test
```

## Key URLs (set in .env)

```bash
source .env
echo "Kibana: ${KIBANA_URL}"
echo "ES:     ${ELASTICSEARCH_URL}"
```

---

## What's Simulated vs Real

Be transparent — technically sophisticated audiences will ask:

| Component | Real | Simulated |
|---|---|---|
| OTel instrumentation | ✅ Real EDOT agents on all services | — |
| Elastic Cloud Serverless | ✅ Live project, real ingest | — |
| Kafka | ✅ Confluent-compatible, traced end-to-end | — |
| Traffic load | ✅ Load generator → storefront → api-gateway (full path, service map complete) | — |
| Mobile RUM | ❌ | Load generator sends mobile-shaped requests |
| AWS Lambda | ❌ | Not wired in this build |
| Fleet-managed Elastic Agent | ✅ Enrolled, system integration collecting host metrics | — |
| Universal Profiling | — | Available in Elastic Cloud; requires Linux host with BTF kernel |
| Alert rules (latency, errors, SLO burn rate) | ✅ 3 rules provisioned, fire during trigger-incident | — |
| Slack alert routing | ✅ Slack API connector provisioned via Terraform (`TF_VAR_slack_token` + `TF_VAR_slack_channel_id`); wired to all 3 alert rules | — |
