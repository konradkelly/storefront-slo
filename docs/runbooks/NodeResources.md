# NodeRootDiskFillingUp / NodeMemoryLow

**Severity:** ticket. k3s on EC2 only (`k8s/monitoring/node-alerts.yaml`). Fires when a node's root disk has been
over 85% full, or its available memory under 10%, for 15 minutes.

## What it means

On k3s you own the nodes, and nothing replaces a sick one for you. One disk holds container images, container logs
and the local-path volumes, so a full disk stops Postgres writes and stops the kubelet from pulling images or
starting pods. Low memory comes before the kernel OOM killer, which kills whatever it chooses, not necessarily
the pod that's growing.

## First five minutes

1. **Which node, and what's on it?**
   ```bash
   kubectl --context k3s-storefront get nodes -o wide
   kubectl --context k3s-storefront top nodes
   kubectl --context k3s-storefront get pods -A -o wide --field-selector spec.nodeName=<node>
   ```
2. **Get a shell on the node** (no SSH; port 22 is closed):
   ```bash
   aws ssm start-session --target <instance-id>   # instance IDs: terraform -chdir=terraform/aws/k3s output
   ```

## Disk

| Cause | How to confirm | Mitigation |
|-------|----------------|------------|
| Unused images | `sudo k3s crictl images`, `sudo du -sh /var/lib/rancher/k3s/agent/containerd` | `sudo k3s crictl rmi --prune` |
| Postgres volume growing (WAL piling up) | `sudo du -sh /var/lib/rancher/k3s/storage/*`. Check WAL archiving: `kubectl -n storefront get cluster storefront-db -o jsonpath='{.status.conditions}'` (ContinuousArchiving). | If archiving to S3 fails, WAL stays on disk until it succeeds: fix the credentials or bucket first. |
| Container logs | `sudo du -sh /var/log/pods` | Find the noisy pod and fix its logging. |
| Disk too small for the workload | None of the above | Raise `root_volume_gb` and grow the volume (EBS supports online resize, then `sudo xfs_growfs /`). |

## Memory

| Cause | How to confirm | Mitigation |
|-------|----------------|------------|
| Pods without memory limits | `kubectl top pods -A --sort-by=memory` | Add limits. Every storefront workload has one. Check the add-ons. |
| Too many pods on one node | `kubectl describe node <node>`: "Allocated resources" | Spread them out, or add an agent (`agent_count`). |
| k3s server components (server node only) | `ps aux --sort=-rss | head` on the node | The control plane shares the node with workloads in 4a. That's one of the costs EKS removes. |
