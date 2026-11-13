# PostgresWalArchivingStuck

**Severity:** ticket. k3s on EC2 only (`k8s/overlays/k3s/backup-alerts.yaml`). Fires when a Postgres instance has
had a WAL segment waiting to be archived to S3 for 15 minutes.

## What it means

Postgres hands each closed WAL segment to the Barman Cloud sidecar, which copies it to S3. Until that works again:

- a restore loses every write after the last archived segment;
- a base backup taken meanwhile can't be restored. The backup finishes as DONE, but its last segment never reaches
  S3. On 2026-11-12 that broke the next `make up`'s restore ("WAL ends before end of online backup");
- WAL piles up on the node's disk.

CloudNativePG keeps reporting the cluster healthy, and the archiver may not count any failures: on 2026-11-12 its
archived and failed counts both stayed flat for 3.5 hours.

## First five minutes

1. **Failing or hung?**
   ```bash
   kubectl --context k3s-storefront -n storefront exec storefront-db-1 -c postgres -- psql -U postgres -c \
     'select archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_wal, last_failed_time from pg_stat_archiver'
   kubectl --context k3s-storefront -n storefront get cluster storefront-db \
     -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
   ```
   A rising `failed_count` means the archive command fails (read its error below). Flat counts mean it hangs.
2. **The sidecar's log and restarts:**
   ```bash
   kubectl --context k3s-storefront -n storefront logs storefront-db-1 -c plugin-barman-cloud --tail=100
   kubectl --context k3s-storefront -n storefront get pod storefront-db-1 \
     -o jsonpath='{range .status.initContainerStatuses[*]}{.name} restarts={.restartCount} {.lastState}{"\n"}{end}'
   ```
3. **The plugin's own pod**, which the sidecar needs:
   ```bash
   kubectl --context k3s-storefront -n cnpg-system get pods
   ```

| Cause | How to confirm | Mitigation |
|-------|----------------|------------|
| S3 credentials or bucket | `failed_count` rising, the sidecar logs AccessDenied or NoSuchBucket | Rerun `scripts/k3s-up.sh`, which recreates Secret `storefront-backup-s3` from Terraform. |
| Sidecar killed for memory (256Mi limit in `backups.yaml`) | `lastState` shows OOMKilled, often during the 03:00 base backup | Raise the limit in `k8s/overlays/k3s/backups.yaml`. |
| Archive command hung | Counts flat, sidecar running, nothing in its log | Delete the primary's pod. CloudNativePG fails over to the replica (or restarts the pod, with one instance), and the new primary archives. Check that `archived_count` moves. |
| Plugin pod down | No running pod in `cnpg-system` | Find out why (node down, image pull). The sidecar can't archive without it. |

## Afterwards

Base backups taken during the stall stay unrestorable. The next `make up` sets them aside (`unrestorable/` in the
archive), but take a fresh one now so the newest backup is a good one:

```bash
cat <<EOF | kubectl --context k3s-storefront apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: storefront-db-after-stall-$(date -u +%Y%m%d%H%M)
  namespace: storefront
spec:
  cluster:
    name: storefront-db
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
```
