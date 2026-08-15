# What was actually broken?

The `catalog` Service, its EndpointSlice, and `allow-frontend-to-catalog` policy
were valid. The difference was kube-proxy's handling of the source address on
the Service path.

The cluster was originally configured with `10.244.0.0/16` as its Pod range,
and kube-proxy received the same value. Later, the active Calico IP pool was
changed to `10.245.0.0/16` without updating kube-proxy. In iptables mode,
kube-proxy uses `clusterCIDR` to decide whether a connection to a ClusterIP came
from inside the cluster.

Because the `frontend` Pod address was outside kube-proxy's `clusterCIDR`, the
Service rule marked the connection for masquerading. The remote `catalog`
backend consequently saw a node address instead of the frontend Pod identity.
Calico's selector-based policy could no longer associate the packet with
`app=frontend`, so it dropped the request.

Direct Pod-IP access bypassed the Service NAT rule. Its workload identity stayed
intact, which is why the same policy allowed that path.

## Repair options

First identify the cluster's real Pod range:

```bash
kubectl get nodes \
  -o custom-columns=NAME:.metadata.name,POD_CIDR:.spec.podCIDR

kubectl get ippools.crd.projectcalico.org
```

### Option 1: detect Calico workload interfaces

For this cluster, interface-based local detection is the more targeted repair.
It avoids broadening kube-proxy's local CIDR classification. Confirm that the
workload interfaces use Calico's `cali` prefix:

```bash
docker exec storefront-lab-control-plane \
  ip -o link show | grep cali
```

Edit the embedded kube-proxy configuration:

```bash
kubectl -n kube-system edit configmap kube-proxy
```

Set these fields in `config.conf`:

```yaml
detectLocalMode: InterfaceNamePrefix
detectLocal:
  interfaceNamePrefix: cali
```

The related kube-proxy flags are `--detect-local-mode` and
`--pod-interface-name-prefix`, but they are ignored when kube-proxy is started
with `--config`, as it is here. Change the ConfigMap fields instead.

This repair is coupled to the CNI's interface naming. Revisit it if the cluster
moves away from Calico or changes dataplanes.

### Option 2: cover every workload CIDR

Alternatively, keep `detectLocalMode: ClusterCIDR` and change `clusterCIDR` so
it covers every node Pod CIDR and workload address. The smallest range covering
both `10.244.0.0/16` and `10.245.0.0/16` is:

```yaml
detectLocalMode: ClusterCIDR
clusterCIDR: 10.244.0.0/15
```

This is simpler, but it classifies the entire combined range as local. Avoid
using a broader CIDR than the cluster actually owns.

After either repair, restart kube-proxy so each node rebuilds its Service
rules:

```bash
kubectl -n kube-system rollout restart daemonset kube-proxy
kubectl -n kube-system rollout status daemonset kube-proxy
```

Finally, verify both the authorized and denied paths:

```bash
kubectl -n storefront exec frontend -- curl -fsS --max-time 5 http://catalog

# This must still fail.
kubectl -n storefront exec reporting -- curl -fsS --max-time 5 http://catalog
```

In a production cluster, choose address ranges and local-detection behavior
deliberately. An overly broad CIDR can classify genuinely external sources as
local, while an interface prefix can become stale when the CNI changes.
