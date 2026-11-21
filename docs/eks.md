# EKS (Phase 4b)

The same storefront on Amazon EKS, replacing the pieces k3s made us run ourselves ([k3s.md](k3s.md), "What I had to
run myself"). It's being built in slices, each working before the next
([ROADMAP](ROADMAP.md#phase-4b-migrate-to-eks-later-sprint)):

1. **The cluster**: network, control plane, nodes, EKS add-ons, nightly destroy. *Written; not yet applied.*
2. The platform: Argo CD and `k8s/platform` on EKS, Envoy Gateway behind a Network Load Balancer, Postgres on EBS,
   backups through Pod Identity instead of a static key.
3. The database: the EKS database as a replica of the k3s archive in S3, and a cutover rehearsal.
4. External Secrets, for the Secrets `make up` still creates from local files.
5. The cutover: a domain, weighted DNS (10% → 50% → 100%), then the zone-failure experiment.

```
terraform/aws/bootstrap   once: state and backup buckets, budget, the CI role (now also allowed to destroy EKS)
terraform/aws/eks         make eks-up / make eks-down: VPC, EKS control plane, node group, add-ons
```

## Using it

Apply the bootstrap change once first. The nightly destroy's role needs it to destroy EKS, and without it a
forgotten cluster keeps running:

```bash
terraform -chdir=terraform/aws/bootstrap apply
make eks-up      # 15-20 minutes; writes ~/.kube/storefront-eks.yaml (context eks-storefront)
make eks-down    # about 15 minutes
make eks-plan    # what would change, without changing it
```

kubectl calls `aws eks get-token` for every request, so the AWS CLI must be logged in as the identity that ran
`make eks-up`: EKS made that identity the cluster admin. The API's public endpoint admits only the IP you ran it
from; rerun `make eks-up` after your IP changes.

The nightly destroy ([k3s-nightly-destroy.yml](../.github/workflows/k3s-nightly-destroy.yml)) destroys EKS as well
as k3s, and `make keep HOURS=…` keeps both.

## Cost (us-east-1, on-demand)

| Piece | Price |
|-------|-------|
| EKS control plane, standard support | $0.100/hr |
| 3 × t3.medium nodes | $0.125/hr |
| NAT gateway | $0.045/hr, plus $0.045 per GB through it |
| The NAT gateway's public IPv4 | $0.005/hr |
| 3 × 30 GB gp3 root volumes | about $0.010/hr |
| **Total** | **about $0.28/hr, $6.80/day** |

That's about $0.09/hr more than k3s ($0.19/hr). The control plane costs about what the k3s server did, and the NAT
gateway is most of the difference. Slice 2 adds a Network Load Balancer (about $0.04/hr with its public IPs).

## Choices

| Choice | Why | What it costs |
|--------|-----|---------------|
| **Its own VPC** (10.50.0.0/16) and Terraform stack | The cutover runs both clusters at once, and `make down` destroys the k3s VPC. The clusters share only the backup bucket. | Nothing; a different CIDR keeps peering possible. |
| **Private subnets, one NAT gateway** | Nodes and pods have no public IPs. | If the NAT's zone fails, every node loses outbound traffic. Three NAT gateways would cost $0.09/hr more. |
| **S3 gateway endpoint** | Backups and the layers of EKS's own images (ECR serves them from S3) skip the NAT, and its per-GB charge. | Free. |
| **Kubernetes 1.35** | 1.34 (kind, k3s) leaves standard support on 2026-12-01, and extended support is $0.60/hr. 1.35 is supported until 2027-03-26, and one minor ahead is within the version skew policy. | kind and k3s are one minor behind until all three are upgraded. |
| **`upgrade_policy: STANDARD`** | At the end of standard support EKS upgrades the cluster instead of charging for extended support. | An upgrade you didn't choose, if one is ever left that long. |
| **Managed node group**, 3 × t3.medium, one per zone | AWS replaces and upgrades the nodes. | No autoscaling beyond 3 nodes. Karpenter is a later step. |
| **Prefix delegation, 40 pods per node** | Without it the VPC CNI fits 17 pods on a t3.medium; this stack needs about 22 per node. | The EKS AMI reserves kubelet memory per possible pod: about 700 MiB per node at 40, 1.4 GiB at 110. |
| **IMDSv2 with hop limit 1** | Pods can't reach the node's IAM role, as on k3s. | Controllers that read instance metadata need their region and VPC passed in (the load balancer controller, slice 2). |
| **EKS Pod Identity** for workloads | Short-lived credentials per service account; the EBS CSI driver uses it now, and the backup sidecar will instead of a static key. | Nothing. |
| **NetworkPolicy by the VPC CNI** | k3s enforced it with kube-router, kind with Calico. | To check with `scripts/netpol-check.sh` once the platform runs. |
| **Access entries** (EKS API), not the aws-auth ConfigMap | Who can use the cluster lives in EKS and Terraform. | Only the identity that ran `make eks-up` is admin. |
| **No control-plane logs** | CloudWatch ingestion costs $0.50 per GB, and audit logs are large. | Turn on `api` and `audit` when debugging. |

## What `make eks-down` cleans up

Kubernetes creates AWS resources that Terraform doesn't own: load balancers (AWS Load Balancer Controller), EBS
volumes (EBS CSI driver) and network interfaces (VPC CNI). A load balancer or interface left in a subnet stops the
VPC from being deleted, and a volume left behind keeps costing money. So
[scripts/eks-down.sh](../scripts/eks-down.sh) first deletes the nodes, which stops those controllers. Then it deletes
what they left, by the tags they put on it, destroys the rest, and finally deletes freed volumes tagged
`storefront/cluster=storefront-eks`. It uses AWS APIs only, so the nightly destroy runs the same script.

Postgres's volumes go too, as on k3s: what survives is its archive in S3.
