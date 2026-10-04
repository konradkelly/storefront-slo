# StorefrontApiDown

**Severity:** page. Fires when Prometheus hasn't been able to scrape any `storefront-api` target for 2 minutes,
or when the target has disappeared entirely.

## What it means

Either the app is down, or Prometheus can't see it. Both are urgent: while it fires, the SLO alerts are
blind, because an app that isn't running records no failed requests. Alertmanager mutes the SLO burn
alerts while this one fires, so it's the only page you'll get.

## First five minutes

1. **Is the app serving?** Ask it directly, from outside Prometheus:
   ```bash
   curl -s localhost:8080/actuator/health            # Compose
   kubectl -n storefront get pods -l app=storefront-api
   kubectl -n storefront port-forward svc/storefront-api 8080 && curl -s localhost:8080/actuator/health
   ```
   - **App down:** customers are affected. Go to *App down* below.
   - **App up:** it's a monitoring problem. Go to *Scrape broken* below. Customers are fine, but you can't see
     the SLOs, so treat it as urgent anyway.
2. **What does Prometheus see?** Status → Targets, or `up{job="storefront-api"}`. The error on the target
   (connection refused, timeout, 404) tells you which case it is.

## App down

| Cause | How to confirm | Mitigation |
|-------|----------------|------------|
| Crash loop | `kubectl -n storefront get pods` shows CrashLoopBackOff. `kubectl -n storefront logs deploy/storefront-api --previous`. | Fix by cause. If a deploy started it: `kubectl -n storefront rollout undo deploy/storefront-api`. |
| Can't reach Postgres at startup | Logs show connection refused or auth errors for `storefront-db-rw`. | Check the database cluster: `kubectl -n storefront get cluster storefront-db` (phase, ready instances, current primary). If no instance is ready, see `kubectl -n storefront describe cluster storefront-db` and the CloudNativePG operator logs in `cnpg-system`. |
| Out of memory | `kubectl describe pod` shows `OOMKilled`. | Raise the memory limit. Look for a leak if usage keeps growing. |
| Container stopped (Compose) | `docker compose ps` shows it exited. | `docker compose up -d storefront-api`, then read `docker compose logs storefront-api`. |

## Scrape broken (app is fine)

| Cause | How to confirm | Mitigation |
|-------|----------------|------------|
| ServiceMonitor not picked up (kind) | Target missing from Prometheus entirely. | The ServiceMonitor needs the label `release: kps`. Check `kubectl -n storefront get servicemonitor -o yaml`. |
| Metrics path or port changed | Target shows 404 or connection refused while `/actuator/health` works. | Restore `/actuator/prometheus` exposure (`management.endpoints.web.exposure.include`) or fix the port name. |
| Network policy blocks Prometheus | Target shows a timeout. | Allow traffic from the monitoring namespace (relevant after Phase 2's NetworkPolicies). |

## After

Postmortem ([template](../postmortem-template.md)). If customers were affected, estimate the budget spent from
the outage length. The SLIs didn't record it, so that budget burn is invisible to the SLO dashboards.
