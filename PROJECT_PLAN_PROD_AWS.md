# Project Plan — Make the Cloud Story Real (+ close remaining brief gaps)

**Owner:** Tim Brophy · **Context:** ecomm-otel enterprise observability demo (80-min window)
**Goal:** Turn the narrated multi-cloud story into a demonstrable one, and close the three
smaller must-show gaps the script skips. Ordered by demo impact.

---

## Workstream A — `prod` environment deployed to AWS (primary)

**Why:** The brief's customer is multi-cloud (AWS + GCP + Confluent) and lock-in sensitive.
The script opens with "a real stack, not a sandbox" but runs entirely on the presenter's
laptop except the profiling EC2. The "collector runs anywhere / multi-cloud" claim (UC4) is
spoken, never shown. `infra/aws/` was scoped for `ECS, ALB, MSK, Lambda` (per CLAUDE.md) but
only builds the profiling host.

**Outcome:** the same seven services running in AWS, collector forwarding from AWS →
the *same* Elastic Cloud Serverless project, so the demo shows one unified view spanning
"laptop + cloud." Makes UC4's multi-cloud + "bring your own collector" answers live, and
backs the UC1 opening claim.

### Recommended path — phased

**Phase A1 — `prod` compose profile + one EC2 host (fast, cheap, proves it).**
- Add `docker-compose.prod.yml` override: production-ish settings (no simulators, resource
  limits, `restart: unless-stopped`, prod `OTEL_RESOURCE_ATTRIBUTES` incl.
  `deployment.environment=prod`, `cloud.provider=aws`, `cloud.region`).
- Reuse the existing `infra/aws` EC2 + SSM + user_data pattern (already proven for the
  profiling host) to stand up a `prod-app` EC2 that pulls images and runs the prod compose.
- Collector on the host forwards to the existing mOTLP ingest endpoint → data lands in the
  same project, tagged `deployment.environment=prod` so it's filterable vs. local.
- `demo.sh` verbs: `apply-prod-host`, `deploy-prod-stack`, `teardown-prod`.
- **Effort:** ~1 day. **Cost:** one EC2 instance, teardownable.

**Phase A2 — ECS Fargate + ALB + ECR (enterprise-credible, stretch).**
- ECR repos per service (push from local build or CI).
- ECS Fargate services behind an ALB; collector as a sidecar or dedicated task.
- Managed Kafka: **MSK** (closest to the Confluent narrative) or keep self-hosted Kafka in a
  task to control cost.
- Terraform under `infra/aws/` finally matches the CLAUDE.md-promised `ECS, ALB, MSK`.
- **Effort:** ~2–3 days. **Cost:** materially higher (ALB + Fargate + MSK) — needs a
  teardown discipline and an AE cost sign-off before standing it up.

> **Recommendation:** ship **A1 before the demo** (low risk, genuinely proves cloud
> deployment + remote collector). Treat **A2 as post-demo hardening / the "at scale" answer**
> unless the eval explicitly demands cloud-native orchestration on the call.

### Open decisions (need your call — they change scope)
1. **Fidelity:** A1 (EC2-compose) only for the demo, or push to A2 (ECS/Fargate/MSK)?
2. **GCP:** in scope for this pass? Running the collector *or* one service on GKE/GCE would
   make it genuinely multi-cloud (unified view across AWS+GCP), but roughly doubles A-effort.
   Default assumption: **AWS only for now**, GCP stays narrated.
3. **Kafka in cloud:** MSK (on-message with Confluent story, higher cost) vs. self-hosted in a
   task (cheap). Default: **self-hosted** unless MSK is a named evaluation criterion.
4. **Timeline:** demo date drives A1-only vs. A1+A2.

---

## Workstream B — Close UC1 must-shows the script skips

**B1 — PII masking beat (UC1).** Brief lists card/email masking as a must-show and the test
suite checks it, but the script never demonstrates it. Add a ~2-min beat: raw checkout span in
Dev Tools showing `card_number`/`email` masked, plus the masking rule as code
(`platform/ingest-pipelines/`). GDPR-sensitive customer — this is a strong, cheap win.

**B2 — Universal Profiling in the UC1 flow.** It's a brief must-show ("hot method in Java
service") but sits in the Q&A table. Promote a 2–3 min beat: profiling Kibana tab → flame graph
→ the FraudShield hot path. Infra already exists (stateful ESS + EC2 stress workload).

---

## Workstream C — UC3 drift proof

The brief's UC3 proof point is *"`terraform plan` shows zero changes to the central layer after
team additions."* The script shows the two layers but never runs it. Add a live
`terraform plan` on `infra/elastic` after `provision-team`, showing **No changes** — the
concrete governance proof.

---

## Workstream D — Cleanup

- Relabel the "UC5" references in Demo Controls (knowledge base / agent / workflow) — the brief
  folds autonomous investigation into UC1.
- Tighten UC4 snapshot demo (currently points at a placeholder S3 bucket).

---

## Suggested sequence

1. **A1** — prod on AWS (biggest demo impact, ~1 day).
2. **B1 + B2** — PII masking + profiling beats (cheap, high brief-alignment).
3. **C** — drift proof (small).
4. **D** — cleanup.
5. **A2** — ECS/Fargate/MSK, post-demo unless required on the call.

**Dev loop reminder (CLAUDE.md):** run `./scripts/demo.sh test` before and after each change;
report the test delta, not the code.
