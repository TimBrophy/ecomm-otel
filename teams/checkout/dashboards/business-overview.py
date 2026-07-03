#!/usr/bin/env python3
"""
Deploy the Checkout Business Overview dashboard to the product-team Kibana space.

Uses the _import endpoint (required on Serverless) with separate lens saved objects.

Panels:
  Row 1 — KPIs: Checkouts, Avg Checkout Time (ms), Orders Fulfilled, P95 Latency (ms)
  Row 2 — Time series: Checkout Throughput, Checkout Latency over time
  Row 3 — Breakdowns: Fraud Detection Impact, Service Request Volume
"""
import json
import os
import sys
import urllib.request
import urllib.error

KIBANA_URL = os.environ.get("KIBANA_URL", "").rstrip("/")
API_KEY = os.environ.get("ELASTIC_INGEST_API_KEY", "")
ELASTIC_USERNAME = os.environ.get("ELASTIC_USERNAME", "")
ELASTIC_PASSWORD = os.environ.get("ELASTIC_PASSWORD", "")
SPACE_ID = None  # no space prefix — product team has its own project
DASH_ID = "checkout-business-overview"
# Remote cluster prefix: data lives in the platform project, queried via CPS
INDEX = "platform:traces-generic.otel-default"

CORE_MIG_VER = "8.8.0"
LENS_MIG_VER = "8.9.0"
DASH_MIG_VER = "8.9.0"


def auth_header():
    if API_KEY:
        return f"ApiKey {API_KEY}"
    if ELASTIC_USERNAME and ELASTIC_PASSWORD:
        import base64
        token = base64.b64encode(f"{ELASTIC_USERNAME}:{ELASTIC_PASSWORD}".encode()).decode()
        return f"Basic {token}"
    raise RuntimeError("No auth: set ELASTIC_INGEST_API_KEY or ELASTIC_USERNAME/ELASTIC_PASSWORD")


def make_lens_metric(lens_id, title, esql, col_id):
    """Create a lens saved object for a single metric (COUNT / AVG / PERCENTILE)."""
    dv_id = f"dv_{lens_id}"
    layer_id = f"l_{lens_id}"
    return {
        "type": "lens",
        "id": lens_id,
        "coreMigrationVersion": CORE_MIG_VER,
        "typeMigrationVersion": LENS_MIG_VER,
        "managed": False,
        "references": [],
        "attributes": {
            "title": title,
            "description": "",
            "visualizationType": "lnsMetric",
            "state": {
                "datasourceStates": {
                    "textBased": {
                        "layers": {
                            layer_id: {
                                "index": dv_id,
                                "query": {"esql": esql},
                                "columns": [{"id": col_id, "fieldName": col_id, "meta": {"type": "number"}}],
                            }
                        }
                    }
                },
                "visualization": {"layerId": layer_id, "layerType": "data", "metricAccessor": col_id},
                "query": {"language": "kuery", "query": ""},
                "filters": [],
                "adHocDataViews": {dv_id: {"type": "esql"}},
                "internalReferences": [{"type": "index-pattern", "id": dv_id, "name": f"textBased_{layer_id}"}],
            },
        },
    }


def make_lens_xy(lens_id, title, esql, cols, x_col, y_cols, series_type="line"):
    """Create a lens saved object for a time series or bar chart."""
    dv_id = f"dv_{lens_id}"
    layer_id = f"l_{lens_id}"
    return {
        "type": "lens",
        "id": lens_id,
        "coreMigrationVersion": CORE_MIG_VER,
        "typeMigrationVersion": LENS_MIG_VER,
        "managed": False,
        "references": [],
        "attributes": {
            "title": title,
            "description": "",
            "visualizationType": "lnsXY",
            "state": {
                "datasourceStates": {
                    "textBased": {
                        "layers": {
                            layer_id: {
                                "index": dv_id,
                                "query": {"esql": esql},
                                "columns": cols,
                            }
                        }
                    }
                },
                "visualization": {
                    "preferredSeriesType": series_type,
                    "legend": {"isVisible": True, "position": "bottom"},
                    "valueLabels": "hide",
                    "layers": [
                        {
                            "layerId": layer_id,
                            "layerType": "data",
                            "seriesType": series_type,
                            "accessors": y_cols,
                            "xAccessor": x_col,
                            "yConfig": [],
                        }
                    ],
                },
                "query": {"language": "kuery", "query": ""},
                "filters": [],
                "adHocDataViews": {dv_id: {"type": "esql"}},
                "internalReferences": [{"type": "index-pattern", "id": dv_id, "name": f"textBased_{layer_id}"}],
            },
        },
    }


def panel_ref(panel_id, lens_id, ref_name, grid):
    """Build a dashboard panel that references a lens saved object."""
    return {
        "type": "lens",
        "panelIndex": panel_id,
        "gridData": {**grid, "i": panel_id},
        "version": "8.11.0",
        "panelRefName": ref_name,
        "embeddableConfig": {"hidePanelTitles": False, "enhancements": {}},
    }


def build():
    lens_objects = []
    panels = []
    references = []

    def add(lens_obj, panel_id, grid):
        lens_objects.append(lens_obj)
        ref_name = f"panel_{len(references)}"
        panels.append(panel_ref(panel_id, lens_obj["id"], ref_name, grid))
        references.append({"name": ref_name, "type": "lens", "id": lens_obj["id"]})

    checkout_filter = f'`resource.attributes.service.name` == "checkout-service" AND `span.name` == "POST /checkout"'
    order_filter = f'`resource.attributes.service.name` == "order-service" AND `span.name` == "POST /orders"'

    # ── Row 1: KPIs ───────────────────────────────────────────────────────────
    add(make_lens_metric(
        "co-checkout-count", "Checkouts",
        f"FROM {INDEX} | WHERE {checkout_filter} | STATS total = COUNT(*)",
        "total",
    ), "p_kpi1", {"x": 0, "y": 0, "w": 12, "h": 5})

    add(make_lens_metric(
        "co-checkout-avg", "Avg Checkout Time (ms)",
        f"FROM {INDEX} | WHERE {checkout_filter} | STATS avg_ms = ROUND(AVG(`duration`) / 1000000, 0)",
        "avg_ms",
    ), "p_kpi2", {"x": 12, "y": 0, "w": 12, "h": 5})

    add(make_lens_metric(
        "co-order-count", "Orders Fulfilled",
        f"FROM {INDEX} | WHERE {order_filter} | STATS total = COUNT(*)",
        "total",
    ), "p_kpi3", {"x": 24, "y": 0, "w": 12, "h": 5})

    add(make_lens_metric(
        "co-checkout-p95", "P95 Checkout Latency (ms)",
        f"FROM {INDEX} | WHERE {checkout_filter} | STATS p95_ms = ROUND(PERCENTILE(`duration`, 95) / 1000000, 0)",
        "p95_ms",
    ), "p_kpi4", {"x": 36, "y": 0, "w": 12, "h": 5})

    # ── Row 2: Time series ────────────────────────────────────────────────────
    add(make_lens_xy(
        "co-checkout-ts", "Checkout Throughput (5-min buckets)",
        f"FROM {INDEX} | WHERE {checkout_filter} | STATS requests = COUNT(*) BY bucket_ts = BUCKET(@timestamp, 5 minute) | SORT bucket_ts ASC",
        [
            {"id": "bucket_ts", "fieldName": "bucket_ts", "meta": {"type": "date"}},
            {"id": "requests", "fieldName": "requests", "meta": {"type": "number"}},
        ],
        "bucket_ts", ["requests"],
    ), "p_ts1", {"x": 0, "y": 5, "w": 24, "h": 10})

    add(make_lens_xy(
        "co-latency-ts", "Checkout Latency Over Time (ms)",
        f"FROM {INDEX} | WHERE {checkout_filter} | STATS avg_ms = ROUND(AVG(`duration`) / 1000000, 0), p95_ms = ROUND(PERCENTILE(`duration`, 95) / 1000000, 0) BY bucket_ts = BUCKET(@timestamp, 5 minute) | SORT bucket_ts ASC",
        [
            {"id": "bucket_ts", "fieldName": "bucket_ts", "meta": {"type": "date"}},
            {"id": "avg_ms", "fieldName": "avg_ms", "meta": {"type": "number"}},
            {"id": "p95_ms", "fieldName": "p95_ms", "meta": {"type": "number"}},
        ],
        "bucket_ts", ["avg_ms", "p95_ms"],
    ), "p_ts2", {"x": 24, "y": 5, "w": 24, "h": 10})

    # ── Row 3: Breakdowns ─────────────────────────────────────────────────────
    add(make_lens_xy(
        "co-fraud-impact", "Fraud Detection: Latency by Flag State",
        f"FROM {INDEX} | WHERE {checkout_filter} | STATS avg_ms = ROUND(AVG(`duration`) / 1000000, 0), p95_ms = ROUND(PERCENTILE(`duration`, 95) / 1000000, 0) BY flag_state = `attributes.feature_flag.realtime_fraud_detection` | SORT avg_ms DESC",
        [
            {"id": "flag_state", "fieldName": "flag_state", "meta": {"type": "string"}},
            {"id": "avg_ms", "fieldName": "avg_ms", "meta": {"type": "number"}},
            {"id": "p95_ms", "fieldName": "p95_ms", "meta": {"type": "number"}},
        ],
        "flag_state", ["avg_ms", "p95_ms"], "bar",
    ), "p_br1", {"x": 0, "y": 15, "w": 24, "h": 8})

    add(make_lens_xy(
        "co-service-vol", "Request Volume by Service",
        f'FROM {INDEX} | WHERE `resource.attributes.service.name` IN ("api-gateway", "checkout-service", "order-service", "notification-service") | STATS requests = COUNT(*) BY svc_name = `resource.attributes.service.name` | SORT requests DESC',
        [
            {"id": "svc_name", "fieldName": "svc_name", "meta": {"type": "string"}},
            {"id": "requests", "fieldName": "requests", "meta": {"type": "number"}},
        ],
        "svc_name", ["requests"], "bar_horizontal",
    ), "p_br2", {"x": 24, "y": 15, "w": 24, "h": 8})

    dashboard = {
        "type": "dashboard",
        "id": DASH_ID,
        "coreMigrationVersion": CORE_MIG_VER,
        "typeMigrationVersion": DASH_MIG_VER,
        "managed": False,
        "attributes": {
            "title": "Checkout Business Overview",
            "description": "Checkout throughput, order volume, and feature flag impact — no p99 required.",
            "version": 1,
            "timeRestore": False,
            "panelsJSON": json.dumps(panels),
            "optionsJSON": json.dumps({"useMargins": True, "syncColors": False, "hidePanelTitles": False}),
            "kibanaSavedObjectMeta": {
                "searchSourceJSON": json.dumps({"query": {"language": "kuery", "query": ""}, "filter": []})
            },
        },
        "references": references,
    }

    return lens_objects + [dashboard]


def main():
    if not KIBANA_URL or not API_KEY:
        print("  ✗ KIBANA_URL or ELASTIC_INGEST_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    objects = build()
    ndjson = ("\n".join(json.dumps(o) for o in objects) + "\n").encode()

    boundary = "KibanaDashImport"
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="dashboard.ndjson"\r\n'
        f"Content-Type: application/ndjson\r\n\r\n"
    ).encode() + ndjson + f"\r\n--{boundary}--\r\n".encode()

    # No space prefix — product team has its own project (no spaces)
    url = f"{KIBANA_URL}/api/saved_objects/_import?overwrite=true"
    import_headers = {
        "Authorization": auth_header(),
        "kbn-xsrf": "true",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    }

    req = urllib.request.Request(url, data=body, headers=import_headers, method="POST")

    try:
        with urllib.request.urlopen(req) as resp:
            result = json.load(resp)
            errors = result.get("errors", [])
            success = result.get("successCount", 0)
            if errors:
                print(f"  ✗ Import errors: {json.dumps(errors)[:400]}", file=sys.stderr)
                sys.exit(1)
            print(f"  ✓ Checkout Business Overview ({success} object(s))")
            print(f"    {KIBANA_URL}/app/dashboards#/view/{DASH_ID}")
    except urllib.error.HTTPError as e:
        body_resp = e.read().decode()
        print(f"  ✗ Failed (HTTP {e.code}): {body_resp[:400]}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
