# EKS Starter — Terraform

Terraform configuration for a production-ready [Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html) cluster, including VPC networking, managed node groups, EBS CSI driver, AWS Load Balancer Controller, and External Secrets Operator — all wired up via [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html).

Originally forked from [HashiCorp's EKS tutorial](https://developer.hashicorp.com/terraform/tutorials/kubernetes/eks) and extended with additional add-ons, variable-driven configuration, and production patterns for research and exploration.

---

## Documentation

| Document | Description |
|---|---|
| [AWS Load Balancer Controller — Implementation](./docs/lbc-implementation.md) | Design decisions and configuration for the LBC add-on. |
| [External Secrets Operator — Implementation](./docs/eso-implementation.md) | Design decisions and configuration for the ESO add-on. |

---

## Architecture

![AWS EKS Architecture](docs/aws-eks-architecture.png)

## Overview

`terraform apply` provisions ~80 resources across five logical groups:

### VPC & Networking

Uses [`terraform-aws-modules/vpc/aws`](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest) v5.8.1.

| Resource | Count | Notes |
|---|---|---|
| VPC | 1 | `/16` CIDR, DNS hostnames enabled |
| Private subnets | 3 | One per AZ, tagged for internal ELB |
| Public subnets | 3 | One per AZ, tagged for public ELB |
| Internet gateway | 1 | Attached to the VPC |
| NAT gateway | 1 | Single gateway (cost-optimized) in a public subnet |
| Elastic IP | 1 | Allocated for the NAT gateway |
| Route tables | 4 | 1 public + 3 private (one per AZ) |

### EKS Cluster & Node Groups

Uses [`terraform-aws-modules/eks/aws`](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest) v20.8.5.

| Resource | Notes |
|---|---|
| EKS control plane | Public endpoint, Kubernetes 1.35 by default |
| OIDC provider | For [IAM Roles for Service Accounts (IRSA)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) |
| Managed node group 1 | `node-group-1`: desired 2, min 1, max 3 |
| Managed node group 2 | `node-group-2`: desired 1, min 1, max 2 |
| Launch templates | One per node group |
| Security groups | Cluster + node groups |
| IAM roles & policies | Cluster role, node instance role |
| [EKS Pod Identity agent](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html) add-on | Installed via cluster add-on |
| [AWS EBS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html) add-on | Installed via cluster add-on |

### EBS CSI Driver — Pod Identity

| Resource | Notes |
|---|---|
| IAM role `AmazonEKSTFEBSCSIRole-<cluster>` | Assumed by the EBS CSI controller pod |
| IAM policy attachment | `AmazonEBSCSIDriverPolicy` (AWS managed) |
| Pod Identity association | Binds `ebs-csi-controller-sa` in `kube-system` to the IAM role |

### AWS Load Balancer Controller — Pod Identity

| Resource | Notes |
|---|---|
| IAM policy `AWSLoadBalancerControllerIAMPolicy-<cluster>` | Fetched from LBC `main` branch (tagged releases have missing permissions) |
| IAM role `AmazonEKSTFLBCRole-<cluster>` | Assumed by the LBC pod via Pod Identity |
| Pod Identity association | Binds `aws-load-balancer-controller` SA in `kube-system` to the IAM role |
| Helm release `aws-load-balancer-controller` | Installed from `eks/aws-load-balancer-controller` chart |

### External Secrets Operator — Pod Identity

| Resource | Notes |
|---|---|
| IAM policy `ExternalSecretsOperatorIAMPolicy-<cluster>` | Secrets Manager + SSM Parameter Store read permissions |
| IAM role `AmazonEKSTFESORRole-<cluster>` | Assumed by the ESO pod via Pod Identity |
| Pod Identity association | Binds `external-secrets` SA in `external-secrets` namespace to the IAM role |
| Helm release `external-secrets` | Installed from `charts.external-secrets.io` chart |

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| [Terraform](https://developer.hashicorp.com/terraform/install) | >= 1.3.2 | `brew install terraform` |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | v2 | `brew install awscli` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | compatible with cluster version | `brew install kubectl` |

Your AWS credentials must have permission to create IAM roles, VPCs, EKS clusters, EC2 instances, and related resources. The Terraform caller is automatically granted `cluster-admin` via `enable_cluster_creator_admin_permissions = true`.

---

## Quickstart

**1. Clone and enter the repo**

```bash
git clone <repo-url>
cd eks-starter
```

**2. Configure variables**

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum, set region and cluster_name_prefix
```

**3. Initialize Terraform**

```bash
terraform init
```

**4. Review the plan**

```bash
terraform plan
```

**5. Apply**
Enter `yes` when prompted.

```bash
terraform apply
```

Provisioning takes approximately 15–20 minutes. If everything succeeds you should see something like:
```
...
Apply complete! Resources: 75 added, 0 changed, 0 destroyed.

Outputs:

cluster_endpoint = "https://<VERY_LONG_IDENTIFIER>.gr7.us-east-2.eks.amazonaws.com"
cluster_name = "eks-starter"
cluster_security_group_id = "sg-0123456789abcdef0"
region = "us-east-2"
```

**6. Configure kubectl config**

```bash
aws eks --region $(terraform output -raw region) update-kubeconfig \
  --name $(terraform output -raw cluster_name)
```

**7. Verify**

Run these checks in order after `terraform apply` completes. Each builds on the previous.

**Nodes — all Ready**
```bash
kubectl get nodes
```
> Expected: 3 nodes (2 from node-group-1, 1 from node-group-2), all STATUS=Ready

**System pods — all Running**
```bash
kubectl get pods -n kube-system
```
> Expected: all pods Running/Completed, none in Pending/CrashLoopBackOff/Error

**EBS CSI driver — Pod Identity wired up**

Controller and node pods running
```bash
kubectl get pods -n kube-system -l app=ebs-csi-controller
```
```bash
kubectl get pods -n kube-system -l app=ebs-csi-node
```

Pod Identity association exists
```bash
aws --no-cli-pager eks list-pod-identity-associations \
  --cluster-name $(terraform output -raw cluster_name) \
  --region $(terraform output -raw region) \
  --query 'associations[?serviceAccount==`ebs-csi-controller-sa`]'
```
> Expected: one entry with namespace=kube-system

**AWS Load Balancer Controller — healthy and watching**

2 replicas running
```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
```
> Expected: `READY 2/2`

No errors in logs (look for "Starting", "successfully acquired lease")
```bash
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller \
  --tail=20
```

Pod Identity association exists
```bash
aws --no-cli-pager eks list-pod-identity-associations --cluster-name $(terraform output -raw cluster_name) --region $(terraform output -raw region) \
  --query 'associations[?serviceAccount==`aws-load-balancer-controller`]'
```
> Expected: one entry with namespace=kube-system

**metrics-server — serving resource metrics**
```bash
kubectl get deployment -n kube-system metrics-server
```
> Expected: READY 1/1

```bash
kubectl top nodes
```
> Expected: CPU and MEMORY usage listed for each node (may take ~60s after first deploy)

---

## Variables

| Variable | Default | Description |
|---|---|---|
| `region` | `us-east-2` | AWS region to deploy into |
| `cluster_name_prefix` | `eks-starter` | Prefix for cluster and VPC names |
| `cluster_version` | `1.35` | [Kubernetes version](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) |
| `ami_type` | `AL2023_x86_64_STANDARD` | [Node AMI type](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html) |
| `instance_types` | `["t3.small"]` | EC2 instance types for both node groups |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR block |
| `private_subnets` | `["10.0.1.0/24", ...]` | Private subnet CIDRs (one per AZ) |
| `public_subnets` | `["10.0.4.0/24", ...]` | Public subnet CIDRs (one per AZ) |
| `lbc_chart_version` | `1.8.2` | Helm chart version for the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) |
| `eso_chart_version` | `0.14.4` | Helm chart version for [External Secrets Operator](https://external-secrets.io/) |
| `eso_secret_arns` | `["*"]` | AWS Secrets Manager ARN patterns ESO is permitted to read |

See [`terraform.tfvars.example`](./terraform.tfvars.example) for a ready-to-copy template.

---

## Outputs

| Output | Description |
|---|---|
| `cluster_name` | EKS cluster name |
| `cluster_endpoint` | API server endpoint URL |
| `cluster_security_group_id` | Security group attached to the control plane |
| `region` | AWS region |
| `eso_iam_role_arn` | IAM role ARN used by the External Secrets Operator |

---

## Teardown

### Pre destroy
Check for any ingress resources tied to AWS load balancers and delete if necessary. These LBs would get orphaned if not explicitly destroyed before cluster deletion.

```bash
kubectl get ingress --all-namespaces
```

If you see ingress resources, delete them first:
```bash
kubectl delete ingress -n <namespace> <ingress-name>
```

You might need to wait a few seconds before the command completes.

Confirm the associated AWS LBs were also deleted with this `aws` cli command:
```bash
aws --no-cli-pager elbv2 describe-load-balancers \
  --region $(terraform output -raw region) \
  --query 'LoadBalancers[*].LoadBalancerName' --output text
```

If there's no output then you should be clear to destroy the cluster.

### Destroy the cluster and associated resources

```bash
terraform destroy
```
