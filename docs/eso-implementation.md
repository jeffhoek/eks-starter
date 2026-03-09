# External Secrets Operator — Terraform Implementation

## Context

This document records the design decisions made when adding the External Secrets Operator (ESO)
to this Terraform project. ESO reads secrets from AWS Secrets Manager and SSM Parameter Store,
syncing them into native Kubernetes `Secret` objects and keeping sensitive values (API keys,
database credentials, tokens) out of Git and out of Helm values files.

---

## Design Decisions

### IAM auth: Pod Identity (not IRSA)

Consistent with the EBS CSI driver and AWS Load Balancer Controller, ESO uses EKS Pod Identity:
- IAM role with `pods.eks.amazonaws.com` trust principal
- `aws_eks_pod_identity_association` binding `external-secrets/external-secrets` SA to the role

**Critical ESO-specific constraint:** When using Pod Identity, the `ClusterSecretStore` must have
NO `auth` section. ESO's controller pod automatically picks up the injected credentials from the
Pod Identity agent. The `serviceAccountRef` field in
`ClusterSecretStore.spec.provider.aws.auth.jwt` is **incompatible** with Pod Identity and must
not be used.

### IAM policy: inline (not fetched from upstream)

Unlike the LBC policy (fetched from upstream due to historical permission drift), the read
permissions for ESO are a stable, minimal set. They are defined inline in `eso.tf` using
`jsonencode` with two statements:

**Secrets Manager:**
```
secretsmanager:GetSecretValue
secretsmanager:DescribeSecret
secretsmanager:ListSecretVersionIds
secretsmanager:ListSecrets
secretsmanager:BatchGetSecretValue
```

`GetResourcePolicy` is intentionally omitted — it is only needed for the `PushSecret` feature,
which is not used here (read-only pull pattern).

The resource scope defaults to `["*"]` via `var.eso_secret_arns`. For production, override this
to a prefix pattern:

```hcl
eso_secret_arns = ["arn:aws:secretsmanager:us-east-2:123456789012:secret:myapp/*"]
```

**SSM Parameter Store:**
```
ssm:GetParameter
ssm:GetParameters
ssm:GetParametersByPath
ssm:DescribeParameters
```

Resource scope is `arn:aws:ssm:*:*:parameter/*` (all parameters). Narrow this in `eso.tf` if
needed for production.

### ClusterSecretStore: post-provision kubectl (not Terraform-managed)

The `ClusterSecretStore` is a CRD resource that requires the ESO Helm release to be applied first
(to install the CRD). Managing it in Terraform via the `kubernetes` provider would create a
provider init-time dependency on a cluster that does not yet exist during `terraform init`.

Instead, the `ClusterSecretStore` resources are applied as a one-time post-provision `kubectl apply` step.
See the [Post-Provision](#post-provision-apply-the-clustersecretstores) section below.

### Helm chart version

Chart: `external-secrets` from `https://charts.external-secrets.io`

Default version: `0.14.4` — the last stable release in the `0.x` series.

**v2 note:** ESO v2.0.x (released early 2026) introduced breaking changes including removal of
unmaintained providers and changes to templating functions. Before upgrading to chart `2.x`,
review the migration guide and update `ClusterSecretStore` / `ExternalSecret` manifests to use
`apiVersion: external-secrets.io/v1` (promoted from `v1beta1`).

CRDs are installed as part of the Helm release (`installCRDs=true`), the recommended approach
for ESO. `create_namespace = true` creates the `external-secrets` namespace inline without
needing the Kubernetes provider.

---

## Resources Added

| Resource | Name pattern | Purpose |
|---|---|---|
| `aws_iam_policy.eso` | `ExternalSecretsOperatorIAMPolicy-<cluster>` | Secrets Manager + SSM Parameter Store read permissions |
| `aws_iam_role.eso` | `AmazonEKSTFESORRole-<cluster>` | Pod Identity role |
| `aws_iam_role_policy_attachment.eso` | — | Binds policy to role |
| `aws_eks_pod_identity_association.eso` | — | Binds `external-secrets/external-secrets` SA to role |
| `helm_release.eso` | `external-secrets` | Installs ESO in `external-secrets` namespace |

---

## Post-Provision: Apply the ClusterSecretStores

After `terraform apply`, apply both `ClusterSecretStore` resources once per cluster:

```bash
REGION=$(terraform output -raw region)

kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${REGION}
      # No auth section — ESO uses Pod Identity credentials automatically
---
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-ssm-parameter-store
spec:
  provider:
    aws:
      service: ParameterStore
      region: ${REGION}
      # No auth section — ESO uses Pod Identity credentials automatically
EOF
```

Verify both stores are ready:

```bash
kubectl get clustersecretstore
```
```
# Expected
NAME                     AGE   STATUS   CAPABILITIES   READY
aws-secrets-manager      17s   Valid    ReadWrite      True
aws-ssm-parameter-store  17s   Valid    ReadWrite      True
```

---

## Using ExternalSecrets in Workloads

Once the `ClusterSecretStore` is in place, create `ExternalSecret` resources in any namespace.

**Sync individual keys from a JSON secret:**

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-credentials
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: my-app-credentials    # Kubernetes Secret name to create
    creationPolicy: Owner
  data:
    - secretKey: api-key         # Key in the Kubernetes Secret
      remoteRef:
        key: my-app/credentials  # Secret name in Secrets Manager
        property: api-key        # JSON property within the secret value
    - secretKey: db-password
      remoteRef:
        key: my-app/credentials
        property: db-password
```

**Sync an entire secret as-is (flat JSON → multiple keys):**

```yaml
spec:
  dataFrom:
    - extract:
        key: my-app/credentials
```

**Sync individual SSM parameters:**

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-ssm-params
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-ssm-parameter-store
    kind: ClusterSecretStore
  target:
    name: my-app-ssm-params    # Kubernetes Secret name to create
    creationPolicy: Owner
  data:
    - secretKey: db-password   # Key in the Kubernetes Secret
      remoteRef:
        key: /my-app/db-password   # Full SSM parameter path
    - secretKey: api-key
      remoteRef:
        key: /my-app/api-key
```

**Sync all parameters under a path prefix:**

```yaml
spec:
  dataFrom:
    - find:
        path: /my-app/          # Fetch all parameters under this prefix
        name:
          regexp: ".*"          # Match all names; use e.g. "^db-" to filter
```

The resulting Kubernetes Secret keys are derived from the parameter name with the path prefix
stripped (e.g., `/my-app/db-password` → `db-password`).

---

## Verification

After `terraform apply` and `kubectl apply` of the `ClusterSecretStore`:

```bash
# ESO pods (expect 3: controller, webhook, cert-controller)
kubectl get pods -n external-secrets

# CRDs installed
kubectl get crd | grep external-secrets.io

# ClusterSecretStore ready
kubectl get clustersecretstore aws-secrets-manager

# ESO controller logs
kubectl logs -n external-secrets \
  -l app.kubernetes.io/name=external-secrets \
  --tail=50

# After creating an ExternalSecret, confirm sync
kubectl get externalsecret -n my-app   # expect STATUS: SecretSynced
```
