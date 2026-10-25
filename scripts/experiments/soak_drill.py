"""The k3s soak drill, run inside the cluster (k8s/monitoring/soak-drill.yaml), so no laptop has to stay on.

On top of the steady k6 soak: a slow burn that should open a ticket and never page, then a fast burn that should
page. A fault is an override on the storefront Argo CD Application (spec.source.kustomize.patches), so self-heal
holds it in place. Remediation removes the override a fixed time after the alert fires, and the rate goes back to
the git value (k8s/overlays/k3s/payment-fault.yaml). Logs one timeline line a minute (snap.py) plus EVENT lines, and
keeps its phase in the soak-drill-state ConfigMap, so a restarted pod resumes. Real Slack notifications go out.

Stop a burn by hand:
  kubectl -n argocd patch application storefront --type merge -p '{"spec":{"source":{"kustomize":null}}}'
"""
import json
import os
import ssl
import time
import urllib.request
from datetime import datetime, timezone

import snap

API = "https://kubernetes.default.svc"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
APP = "/apis/argoproj.io/v1alpha1/namespaces/argocd/applications/storefront"
DEPLOY = "/apis/apps/v1/namespaces/storefront/deployments/storefront-api"
STATE = "/api/v1/namespaces/monitoring/configmaps/soak-drill-state"
LOG = os.environ.get("LOG", "/log/soak-drill.log")


def at(name):
    return datetime.fromisoformat(os.environ[name].replace("Z", "+00:00")).timestamp()


SLOW_AT, PAGE_AT, END_AT = at("SLOW_AT"), at("PAGE_AT"), at("END_AT")
SLOW_RATE = os.environ.get("SLOW_RATE", "0.02")  # 4x burn: exp2
PAGE_RATE = os.environ.get("PAGE_RATE", "0.30")  # 60x burn: exp1
GIT_RATE = "0.001"  # what removing the override goes back to
TICKET_RESPONSE_MIN = int(os.environ.get("TICKET_RESPONSE_MIN", "30"))  # a ticket is worked soon, not dropped-everything
PAGE_RESPONSE_MIN = int(os.environ.get("PAGE_RESPONSE_MIN", "5"))  # as exp1
SLOW_MAX_H = int(os.environ.get("SLOW_MAX_H", "14"))  # remediate anyway if no ticket by then
PAGE_MAX_MIN = int(os.environ.get("PAGE_MAX_MIN", "60"))  # remediate anyway if no page by then

PATCH = """apiVersion: apps/v1
kind: Deployment
metadata:
  name: storefront-api
  namespace: storefront
spec:
  template:
    spec:
      containers:
        - name: storefront-api
          env:
            - name: PAYMENT_FAILURE_RATE
              value: "{rate}"
"""

tls = ssl.create_default_context(cafile=f"{SA}/ca.crt")


def kube(method, path, body=None, content_type="application/merge-patch+json"):
    with open(f"{SA}/token") as f:  # read every time: projected tokens rotate
        token = f.read()
    req = urllib.request.Request(API + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": content_type})
    with urllib.request.urlopen(req, context=tls, timeout=20) as r:
        return json.load(r)


def out(text):
    print(text, flush=True)
    with open(LOG, "a") as f:
        f.write(text + "\n")


def event(text):
    out(f"{datetime.now(timezone.utc):%Y-%m-%d %H:%M:%S} EVENT {text}")


def fault(rate, why):
    """Sets the override, or removes it when rate is None. True if the Application took the change."""
    source = {"kustomize": None} if rate is None else {"kustomize": {"patches": [
        {"target": {"kind": "Deployment", "name": "storefront-api"}, "patch": PATCH.format(rate=rate)}]}}
    try:
        kube("PATCH", APP, {"spec": {"source": source}})
    except Exception as e:
        event(f"patching the Argo CD Application failed ({why}), retrying next minute: {e}")
        return False
    event(f"PAYMENT_FAILURE_RATE={rate or GIT_RATE} ({why}): " +
          ("override removed, back to the git value" if rate is None else "override set on the Argo CD Application"))
    return True


def snapshot(name):
    """An extra Grafana snapshot set, from the grafana-snapshots CronJob's template."""
    job = f"snap-{datetime.now(timezone.utc):%m%d-%H%M}-{name}"
    try:
        template = kube("GET", "/apis/batch/v1/namespaces/monitoring/cronjobs/grafana-snapshots")["spec"]["jobTemplate"]
        kube("POST", "/apis/batch/v1/namespaces/monitoring/jobs",
             {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": job}, "spec": template["spec"]},
             content_type="application/json")
        event(f"snapshot job {job} started")
    except Exception as e:
        event(f"snapshot job {job} failed: {e}")


def rolled_out(rate):
    """True once every API pod runs with this PAYMENT_FAILURE_RATE."""
    d = kube("GET", DEPLOY)
    env = d["spec"]["template"]["spec"]["containers"][0]["env"]
    live = next((e.get("value") for e in env if e["name"] == "PAYMENT_FAILURE_RATE"), None)
    s = d["status"]
    return (live == rate and s.get("observedGeneration", 0) >= d["metadata"]["generation"]
            and s.get("updatedReplicas") == s.get("replicas") == s.get("availableReplicas"))


def alert_states():
    """(ticket, page) for checkout availability: firing, pending or inactive; ? if Prometheus can't be reached."""
    try:
        alerts = json.load(urllib.request.urlopen(f"{snap.PROM}/api/v1/alerts", timeout=10))["data"]["alerts"]
    except Exception:
        return "?", "?"

    def state(severity):
        a = [x for x in alerts if x["labels"]["alertname"] == "StorefrontCheckoutAvailabilityBudgetBurn"
             and x["labels"].get("severity") == severity]
        return a[0]["state"] if a else "inactive"
    return state("ticket"), state("page")


def main():
    data = kube("GET", STATE).get("data") or {}
    phase, since = data.get("phase", "baseline"), float(data.get("since", time.time()))
    event(f"drill running in phase {phase}: slow burn {SLOW_RATE} at {os.environ['SLOW_AT']}, "
          f"fast burn {PAGE_RATE} at {os.environ['PAGE_AT']}, end {os.environ['END_AT']}")
    prev, waiting_for, warned = (None, None), None, False

    def set_phase(p, rate=None):
        nonlocal phase, since, waiting_for
        phase, since, waiting_for = p, time.time(), rate or waiting_for
        event(f"phase {phase}")
        kube("PATCH", STATE, {"data": {"phase": phase, "since": str(since)}})

    while phase != "done":
        try:
            now = time.time()
            mins = (now - since) / 60
            ticket, page = alert_states()
            for name, old, new in (("ticket", prev[0], ticket), ("page", prev[1], page)):
                if old is not None and new != old:
                    event(f"{name} alert: {old} -> {new}")
            prev = (ticket, page)
            out(f"{datetime.now(timezone.utc):%m-%d} {snap.line(phase)}")

            if waiting_for and rolled_out(waiting_for):
                event(f"rollout complete: every API pod has PAYMENT_FAILURE_RATE={waiting_for}")
                snapshot(f"rate-{waiting_for.replace('.', '-')}")
                waiting_for = None

            if phase == "baseline" and now >= SLOW_AT:
                if fault(SLOW_RATE, "slow burn"):
                    set_phase("slow", SLOW_RATE)
            elif phase == "slow":
                if page == "firing" and not warned:
                    warned = True
                    event("PAGE FIRED DURING THE SLOW BURN: it should only open a ticket")
                if ticket == "firing":
                    snapshot("ticket-fired")
                    set_phase("slow-ticket")
                elif mins >= SLOW_MAX_H * 60:
                    event(f"no ticket after {SLOW_MAX_H}h of slow burn, remediating anyway")
                    if fault(None, "remediation, no ticket"):
                        set_phase("recovered-slow", GIT_RATE)
            elif phase == "slow-ticket" and mins >= TICKET_RESPONSE_MIN:
                if fault(None, "remediation"):
                    set_phase("recovered-slow", GIT_RATE)
            elif phase == "recovered-slow" and now >= PAGE_AT:
                if fault(PAGE_RATE, "fast burn"):
                    set_phase("fast", PAGE_RATE)
            elif phase == "fast":
                if page == "firing":
                    snapshot("page-fired")
                    set_phase("fast-page")
                elif mins >= PAGE_MAX_MIN:
                    event(f"no page after {PAGE_MAX_MIN} min of fast burn, remediating anyway")
                    if fault(None, "remediation, no page"):
                        set_phase("recovered-fast", GIT_RATE)
            elif phase == "fast-page" and mins >= PAGE_RESPONSE_MIN:
                if fault(None, "remediation"):
                    set_phase("recovered-fast", GIT_RATE)
            elif phase == "recovered-fast" and now >= END_AT:
                snapshot("end")
                set_phase("done")
        except Exception as e:  # keep going: a missed minute is better than a dead drill
            event(f"error, continuing: {e!r}")
        time.sleep(60)

    event("drill finished. Tear down with: make down && make unkeep")
    while True:  # stay up, so the log keeps being copied to S3 and kubectl logs still works
        time.sleep(3600)


if __name__ == "__main__":
    main()
