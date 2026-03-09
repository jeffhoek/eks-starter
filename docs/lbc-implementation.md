# AWS Load Balancer Controller — Terraform Implementation

## Context

This document records the design decisions made when adding the AWS Load Balancer Controller (LBC)
to this Terraform project.

---

## Design Decisions

### IAM auth: Pod Identity (not IRSA)

The original notes doc specified IRSA because that was the established pattern at the time. PR #1
migrated the EBS CSI driver from IRSA to EKS Pod Identity, which is simpler (no need to reference
the cluster OIDC issuer URL) and is now the preferred approach for new add-ons on this cluster.

LBC follows the same Pod Identity pattern for consistency:
- IAM role with `pods.eks.amazonaws.com` trust principal
- `aws_eks_pod_identity_association` binding `kube-system/aws-load-balancer-controller` to the role

The EKS module still creates an OIDC provider (used implicitly), but it is not referenced here.

### IAM policy source: `main` branch (not a pinned tag)

Tagged releases of the LBC IAM policy have historically lagged behind the permissions actually
required. For example, `elasticloadbalancing:DescribeListenerAttributes` was missing from v2.8.2
and caused failures when the Helm chart was deployed.

The policy is fetched via `data "http"` from:
```
https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
```

This means `terraform plan` will always reflect the latest upstream policy. In practice the LBC
IAM policy is additive-only (permissions are added, not removed), so this approach is safe.

**Note when upgrading the Helm chart:** run `terraform plan` before applying — if the policy has
changed, Terraform will show the IAM policy resource as needing an update.

### Helm chart source

Chart: `aws-load-balancer-controller` from `https://aws.github.io/eks-charts`

The chart version is exposed as `var.lbc_chart_version` (default `1.8.2`) so it can be overridden
per deployment without modifying the module. The chart version maps roughly to the LBC application
version (chart 1.8.x ships LBC v2.8.x).

---

## Resources Added

| Resource | Name pattern | Purpose |
|---|---|---|
| `data.http.lbc_iam_policy` | — | Fetches IAM policy JSON from upstream `main` |
| `aws_iam_policy.lbc` | `AWSLoadBalancerControllerIAMPolicy-<cluster>` | LBC permissions |
| `aws_iam_role.lbc` | `AmazonEKSTFLBCRole-<cluster>` | Pod Identity role |
| `aws_iam_role_policy_attachment.lbc` | — | Binds policy to role |
| `aws_eks_pod_identity_association.lbc` | — | Binds `kube-system/aws-load-balancer-controller` SA to role |
| `helm_release.lbc` | `aws-load-balancer-controller` | Installs LBC in `kube-system` |

---

## Node Group IAM

`AmazonEC2ContainerRegistryReadOnly` is attached to managed node group IAM roles by default in
`terraform-aws-modules/eks/aws` v20 — no explicit action needed for ECR image pulls.

---

## Verification

After `terraform apply`:

```bash
# Check LBC pods are running (expect READY 2/2)
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check LBC logs for any startup errors
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50

# Deploy an Ingress resource and confirm ADDRESS is populated
kubectl get ingress -A
```
