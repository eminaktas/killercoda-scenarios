# Restore the catalog API

The storefront team reports that `frontend` can no longer retrieve data from
the `catalog` Service in the `storefront` namespace. The catalog workload is
running, and the Service has a ready endpoint, but requests from the frontend
time out.

Restore the intended application behavior:

- `frontend` must reach `catalog` on TCP port 80.
- `reporting` must remain unable to reach `catalog`.
- `catalog` must remain a normal ClusterIP Service.
- Existing access controls must not be deleted or relaxed.

Treat this as an infrastructure incident: investigate the cluster state, find
the underlying fault, and repair it without changing the application images.

A reasonable place to begin is the affected namespace:

```bash
kubectl -n storefront get pods,service,endpointslice -o wide
kubectl -n storefront exec frontend -- curl -m 3 http://catalog
```

Click **Check** after restoring the intended behavior.

<details>
<summary>Hint 1 — Narrow the failure</summary>

Test the backend without going through the Service, then compare that result
with the normal Service request:

```bash
CATALOG_IP=$(kubectl -n storefront get pod -l app=catalog \
  -o jsonpath='{.items[0].status.podIP}')

kubectl -n storefront exec frontend -- curl -m 3 "http://${CATALOG_IP}"
kubectl -n storefront exec frontend -- curl -m 3 http://catalog
```

If only one path fails, focus on what changes between those paths.

</details>

<details>
<summary>Hint 2 — Follow the request</summary>

This cluster uses kube-proxy in iptables mode. Inspect its configuration and the
NAT rules for the affected Service. Look for conditions that cause traffic to
be masqueraded.

`kubectl` is configured on the Ubuntu host, but kube-proxy's iptables rules are
inside the Kind node containers. The `frontend` workload runs on the control
plane, so inspect that node directly:

```bash
kubectl -n kube-system get configmap kube-proxy \
  -o go-template='{{index .data "config.conf"}}'

SERVICE_IP=$(kubectl -n storefront get service catalog \
  -o jsonpath='{.spec.clusterIP}')

docker ps --filter name=storefront-lab
docker exec storefront-lab-control-plane \
  iptables-save -t nat | grep "$SERVICE_IP"
```

</details>

<details>
<summary>Hint 3 — Compare configurations</summary>

Compare kube-proxy's local-traffic detection settings with the ranges and
interfaces used by the cluster. A CIDR is not the only supported detector:

```bash
kubectl get nodes \
  -o custom-columns=NAME:.metadata.name,POD_CIDR:.spec.podCIDR

kubectl -n kube-system get configmap kube-proxy \
  -o go-template='{{index .data "config.conf"}}' \
  | grep -E 'clusterCIDR|detectLocalMode|interfaceNamePrefix'

kubectl get ippools.crd.projectcalico.org

kubectl -n storefront get pods -o wide

docker exec storefront-lab-control-plane \
  ip -o link show | grep cali
```

Configuration changes to kube-proxy are not active until its Pods are
restarted.

</details>
