#!/usr/bin/env python3
"""
Deploy the FraudShield Timeout Rate alert rule to the product-team Kibana project.

Rule: fires when fraud_check spans with result=timeout exceed 3 in a 5-minute window.
Project: product-team (the checkout team's own Kibana project, not the platform project).
Rule type: .es-query with ES|QL search type.
"""
import json
import os
import sys
import urllib.request
import urllib.error

KIBANA_URL = os.environ.get("KIBANA_URL", "").rstrip("/")
API_KEY = os.environ.get("ELASTIC_INGEST_API_KEY", "")

RULE_NAME = "FraudShield — Checkout Timeout Rate"


def auth_header():
    if API_KEY:
        return f"ApiKey {API_KEY}"
    raise RuntimeError("No auth: set ELASTIC_INGEST_API_KEY")


def api_request(method, path, data=None):
    url = f"{KIBANA_URL}{path}"
    headers = {
        "Authorization": auth_header(),
        "kbn-xsrf": "true",
        "Content-Type": "application/json",
    }
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def main():
    if not KIBANA_URL or not API_KEY:
        print("  ✗ KIBANA_URL or ELASTIC_INGEST_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    # Check if the rule already exists
    find_path = f"/api/alerting/rules/_find?search=FraudShield&search_fields=name"
    try:
        result = api_request("GET", find_path)
        if result.get("total", 0) >= 1:
            print("  – FraudShield alert already exists")
            sys.exit(0)
    except urllib.error.HTTPError as e:
        body_resp = e.read().decode()
        print(f"  ✗ Failed to query existing rules (HTTP {e.code}): {body_resp[:400]}", file=sys.stderr)
        sys.exit(1)

    # Create the rule
    rule_payload = {
        "name": RULE_NAME,
        "rule_type_id": ".es-query",
        "enabled": True,
        "tags": ["checkout", "fraud", "team-alert"],
        "schedule": {"interval": "1m"},
        "consumer": "alerts",
        "params": {
            "searchType": "esqlQuery",
            "esqlQuery": {
                "esql": (
                    "FROM traces-* "
                    "| WHERE @timestamp > NOW() - 5 minutes "
                    "| WHERE `resource.attributes.service.name` == \"checkout-service\" "
                    "| WHERE name == \"fraud_check\" "
                    "| WHERE `attributes.fraud_check.result` == \"timeout\" "
                    "| STATS timeout_count = COUNT(*) "
                    "| WHERE timeout_count > 3"
                )
            },
            "timeField": "@timestamp",
            "threshold": [0],
            "thresholdComparator": ">",
            "timeWindowSize": 5,
            "timeWindowUnit": "m",
            "size": 100,
        },
        "actions": [],
    }

    try:
        api_request("POST", f"/api/alerting/rule", rule_payload)
        print(f"  ✓ {RULE_NAME} (alert rule created)")
    except urllib.error.HTTPError as e:
        body_resp = e.read().decode()
        print(f"  ✗ Failed to create alert rule (HTTP {e.code}): {body_resp[:400]}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
