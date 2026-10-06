"""Steady synthetic user that logs every failure with a timestamp, independent of the app's own counters (which
reset when pods restart). Runs as a pod inside the cluster during exp4-disruption.sh.

Each loop: GET /products; every 4th loop also add to cart + checkout. About 8 requests/s.
Output: one FAIL line per failed request, and a summary line every 10 s.
"""
import json
import os
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

BASE = os.environ.get("BASE_URL", "http://storefront-api.storefront.svc:8080")
DURATION = int(os.environ.get("DURATION_S", "900"))
TIMEOUT = 5.0  # a request slower than this counts as failed
OK_STATUS = {200, 201, 402, 409}  # 402 payment failed and 409 out of stock are business outcomes, not errors


def now():
    return datetime.now(timezone.utc).strftime("%H:%M:%S")


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method, headers={"Content-Type": "application/json"})
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            status, payload = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, payload = e.code, b""
    except Exception as e:  # connection refused/reset, timeout
        status, payload = type(e).__name__, b""
    return status, time.monotonic() - start, payload


ok = fail = 0
window_ok = window_fail = 0
last = time.monotonic()
end = time.monotonic() + DURATION
loop = 0
product_id = None
while time.monotonic() < end:
    loop += 1
    steps = [("GET", "/products", None)]
    if loop % 4 == 0 and product_id is not None:
        cart = "probe-" + uuid.uuid4().hex[:12]
        steps += [("POST", "/cart/items", {"cartId": cart, "productId": product_id, "quantity": 1}),
                  ("POST", "/orders", {"cartId": cart})]
    for method, path, body in steps:
        status, secs, payload = call(method, path, body)
        if status in OK_STATUS:
            ok += 1
            window_ok += 1
            if path == "/products" and product_id is None:
                product_id = json.loads(payload)[0]["id"]
        else:
            fail += 1
            window_fail += 1
            print(f"{now()} FAIL {method} {path} -> {status} after {secs:.2f}s", flush=True)
            break  # don't check out a cart that failed to fill
    if time.monotonic() - last >= 10:
        print(f"{now()} window ok={window_ok} fail={window_fail} | total ok={ok} fail={fail}", flush=True)
        window_ok = window_fail = 0
        last = time.monotonic()
    time.sleep(0.25)
print(f"{now()} DONE total ok={ok} fail={fail}", flush=True)
