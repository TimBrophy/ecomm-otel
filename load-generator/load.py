"""
Realistic load generator for the ecomm-otel demo.

Scenarios:
  steady   — normal traffic, no failures
  degraded — toggles realtime_fraud_detection flag on after DEGRADED_AFTER_SECONDS, then off after RECOVER_AFTER_SECONDS

Environment:
  TARGET_URL          — api-gateway base URL (default http://api-gateway:8080)
  FLAG_SERVICE_URL    — feature-flag-service URL (default http://feature-flag-service:8090)
  SCENARIO            — steady | degraded (default steady)
  REQUESTS_PER_SECOND — float, default 2.0 (aggregate rate across all workers)
  CONCURRENCY         — parallel worker threads, default 1 (matches prior sequential behaviour)
  DEGRADED_AFTER_SECONDS  — seconds before toggling flag on (default 60)
  RECOVER_AFTER_SECONDS   — seconds the flag stays on before reset (default 120)
"""

import json
import logging
import os
import random
import threading
import time
import urllib.request
import urllib.error

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("load-generator")

TARGET_URL = os.environ.get("TARGET_URL", "http://api-gateway:8080")
FLAG_SERVICE_URL = os.environ.get("FLAG_SERVICE_URL", "http://feature-flag-service:8090")
SCENARIO = os.environ.get("SCENARIO", "steady")
RPS = float(os.environ.get("REQUESTS_PER_SECOND", "2.0"))
CONCURRENCY = max(1, int(os.environ.get("CONCURRENCY", "1")))
DEGRADED_AFTER = float(os.environ.get("DEGRADED_AFTER_SECONDS", "60"))
RECOVER_AFTER = float(os.environ.get("RECOVER_AFTER_SECONDS", "120"))

SAMPLE_EMAILS = [
    "alice@example.com", "bob@example.com", "carol@example.com",
    "dave@example.com", "eve@example.com",
]
SAMPLE_CARDS = [
    "4111111111111111", "5500005555555559", "340000000000009",
]


def post_json(url, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def get_json(url):
    with urllib.request.urlopen(url, timeout=10) as resp:
        return json.loads(resp.read())


def set_flag(name, value):
    try:
        post_json(f"{FLAG_SERVICE_URL}/flags", {"name": name, "value": value})
        log.info("flag %s = %s", name, value)
    except Exception as exc:
        log.warning("flag set failed: %s", exc)


def do_checkout():
    try:
        products = get_json(f"{TARGET_URL}/api/products")
        items = [p["id"] for p in random.sample(products, min(2, len(products)))]
        total = round(random.uniform(20.0, 200.0), 2)
        result = post_json(f"{TARGET_URL}/api/checkout", {
            "email": random.choice(SAMPLE_EMAILS),
            "cardNumber": random.choice(SAMPLE_CARDS),
            "items": items,
            "totalAmount": total,
        })
        log.info("checkout ok orderId=%s", result.get("orderId", "?"))
    except urllib.error.HTTPError as exc:
        log.warning("checkout http %s", exc.code)
    except Exception as exc:
        log.warning("checkout error: %s", exc)


def flag_controller():
    log.info("scenario=degraded, will enable realtime_fraud_detection after %.0fs", DEGRADED_AFTER)
    time.sleep(DEGRADED_AFTER)
    set_flag("realtime_fraud_detection", True)
    log.info("realtime_fraud_detection ON — degraded for %.0fs", RECOVER_AFTER)
    time.sleep(RECOVER_AFTER)
    set_flag("realtime_fraud_detection", False)
    log.info("realtime_fraud_detection OFF — recovered")


def worker(interval):
    while True:
        start = time.time()
        do_checkout()
        elapsed = time.time() - start
        sleep_for = max(0, interval - elapsed)
        time.sleep(sleep_for)


def main():
    log.info("load-generator starting scenario=%s rps=%.1f concurrency=%d target=%s",
              SCENARIO, RPS, CONCURRENCY, TARGET_URL)

    if SCENARIO == "degraded":
        t = threading.Thread(target=flag_controller, daemon=True)
        t.start()

    # Each worker aims for RPS/CONCURRENCY req/s so the aggregate stays ~RPS
    # regardless of worker count. CONCURRENCY=1 reproduces the original
    # strictly-sequential behaviour exactly.
    interval = CONCURRENCY / RPS
    workers = [threading.Thread(target=worker, args=(interval,), daemon=True)
               for _ in range(CONCURRENCY)]
    for t in workers:
        t.start()
    for t in workers:
        t.join()


if __name__ == "__main__":
    main()
