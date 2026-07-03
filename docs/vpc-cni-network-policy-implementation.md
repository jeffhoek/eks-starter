# VPC CNI — NetworkPolicy Enforcement

## Context

This document records why `NetworkPolicy` enforcement is explicitly enabled on the `vpc-cni`
add-on, and how to verify it's actually working. Without this, `kubectl apply -f my-networkpolicy.yaml`
succeeds with no error, but silently enforces nothing.

---

## The Problem

Every EKS cluster's `vpc-cni` add-on ships with NetworkPolicy enforcement *present but disabled by
default*. The node agent (`aws-eks-nodeagent`, part of the `aws-node` DaemonSet) is always running,
and it even reports a `NETWORK_POLICY_ENFORCING_MODE: standard` environment variable — but that's a
red herring. It's a default value baked into the DaemonSet manifest regardless of whether the
feature is actually turned on.

The real toggle is the add-on configuration field `enableNetworkPolicy`, which is unset (defaults
to `false`) unless explicitly configured. Without it:
- No controller watches `NetworkPolicy` objects.
- No `PolicyEndpoint` custom resources get created.
- The node agent has nothing to enforce.

Net effect: any `NetworkPolicy` applied to any namespace on an unconfigured cluster is a silent
no-op. There's no error, no warning, no degraded status — the policy object just exists in etcd
and does nothing.

---

## Design Decision: `configuration_values` on the `vpc-cni` add-on

Enabled in [`main.tf`](../main.tf) via the add-on's `configuration_values` field:

```hcl
vpc-cni = {
  before_compute = true
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })
}
```

This is a one-time, cluster-wide setting — not scoped per namespace or per workload. Applying it
rolls the `aws-node` DaemonSet on every node (brief disruption, cluster-wide). There is no separate
"network-policy-controller" pod to look for in this add-on version — `NetworkPolicy` →
`PolicyEndpoint` reconciliation runs inside the existing `aws-node` / `aws-eks-nodeagent`
containers once the flag is on.

Because it's baked into the Terraform config, every cluster built from this repo gets working
`NetworkPolicy` enforcement from first boot — no manual `aws eks update-addon` step, no
re-discovering this after the fact.

### Manual equivalent (existing clusters)

If updating an existing cluster outside of Terraform:

```bash
aws eks update-addon \
  --cluster-name <cluster-name> \
  --addon-name vpc-cni \
  --resolve-conflicts PRESERVE \
  --configuration-values '{"enableNetworkPolicy":"true"}' \
  --region us-east-2
```

---

## Verification

Addon `status: ACTIVE` is **not sufficient** to confirm this worked — the addon can be active with
the flag silently ignored or misapplied. Verify functionally instead:

**1. Confirm the config value actually landed:**
```bash
aws eks describe-addon \
  --cluster-name $(terraform output -raw cluster_name) \
  --addon-name vpc-cni \
  --region $(terraform output -raw region) \
  --query 'addon.configurationValues'
```
> Expected: `"{\"enableNetworkPolicy\":\"true\"}"`

**2. Apply a `NetworkPolicy` and confirm a `PolicyEndpoint` gets created:**

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: default
spec:
  podSelector: {}
  policyTypes:
    - Ingress
EOF
```

```bash
kubectl get policyendpoints -A
```
> Expected: an object owned by `deny-all-ingress`, not an empty list. If this is empty, the
> `NetworkPolicy` is a no-op regardless of what `kubectl get networkpolicy` reports.

Inspect the resolved rule to confirm it matched the right pods:
```bash
kubectl get policyendpoints -n default -o yaml
```
> Expected: `spec.podSelector` and `spec.ingress`/`spec.egress` reflecting the source
> `NetworkPolicy`, plus `status`/`spec` fields listing the matched pod IPs.

**3. Functional test — confirm traffic is actually blocked:**

Apply a policy that denies cross-namespace ingress to a workload, then from a pod in another
namespace, confirm a connection that used to succeed now fails (timeout, not just a non-200):

```bash
kubectl run netpol-test --rm -it --image=busybox --restart=Never -n <other-namespace> -- \
  wget -qO- --timeout=5 http://<service>.<namespace>.svc.cluster.local
```
> Expected: timeout/connection refused once the policy is in effect; succeeded before it was
> applied.

Only trust NetworkPolicy enforcement on this cluster once both the `PolicyEndpoint` object exists
**and** the functional connectivity test confirms traffic is actually blocked.

---

## Resources Changed

| Resource | Change | Purpose |
|---|---|---|
| `module.eks` `vpc-cni` add-on | `configuration_values` added | Turns on `NetworkPolicy` enforcement cluster-wide |
