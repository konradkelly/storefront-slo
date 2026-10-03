"""One timeline line per call: checkout-availability burn rates, budget left, and alert states."""
import json
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

PROM = "http://localhost:9090"
SLO = "checkout_availability"


def q(expr):
    url = f"{PROM}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    try:
        res = json.load(urllib.request.urlopen(url, timeout=10))["data"]["result"]
    except Exception:
        return None
    return float(res[0]["value"][1]) if res else None


def fmt(v, spec="{:.1f}"):
    return "-" if v is None or v != v else spec.format(v)


def burn(w):
    return q(f"slo:{SLO}:error_ratio_rate{w} / on(slo) (1 - slo:{SLO}:objective)")


phase = sys.argv[1] if len(sys.argv) > 1 else ""
now = datetime.now(timezone.utc).strftime("%H:%M:%S")
burns = " ".join(f"{w}={fmt(burn(w))}" for w in ["5m", "30m", "1h", "6h", "2h", "1d", "3d"])
budget = q(f"1 - slo:{SLO}:error_ratio_rate1d / on(slo) (1 - slo:{SLO}:objective)")
failed = q('sum(increase(storefront_checkouts_total{status="payment_failed"}[1m]))')
total = q('sum(increase(storefront_checkouts_total[1m]))')
try:
    alerts = json.load(urllib.request.urlopen(f"{PROM}/api/v1/alerts", timeout=10))["data"]["alerts"]
    states = ",".join(sorted(f"{a['labels']['alertname'].replace('Storefront', '').replace('BudgetBurn', '')}"
                             f"/{a['labels'].get('severity')}:{a['state']}" for a in alerts)) or "none"
except Exception:
    states = "?"
print(f"{now} [{phase}] burn {burns} | budget1d={fmt(None if budget is None else budget * 100, '{:.1f}')}% "
      f"| checkouts/min={fmt(total, '{:.0f}')} failed/min={fmt(failed, '{:.0f}')} | alerts {states}", flush=True)
