#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "$1" >&2
  exit 1
}

kubectl -n storefront get service catalog -o json | python3 -c '
import json
import sys

service = json.load(sys.stdin)
spec = service["spec"]
assert spec.get("type", "ClusterIP") == "ClusterIP"
assert spec.get("clusterIP") not in (None, "", "None")
assert spec.get("selector", {}).get("app") == "catalog"
assert any(port.get("port") == 80 for port in spec.get("ports", []))
' || fail "catalog must remain a normal ClusterIP Service on port 80."

kubectl -n storefront get networkpolicy allow-frontend-to-catalog -o json | python3 -c '
import json
import sys

policy = json.load(sys.stdin)["spec"]
assert policy.get("podSelector", {}).get("matchLabels", {}).get("app") == "catalog"
assert "Ingress" in policy.get("policyTypes", [])
ingress = policy.get("ingress", [])
assert len(ingress) == 1
sources = ingress[0].get("from", [])
assert len(sources) == 1
assert sources[0].get("podSelector", {}).get("matchLabels", {}).get("app") == "frontend"
assert any(
    port.get("port") == 80 and port.get("protocol", "TCP") == "TCP"
    for port in ingress[0].get("ports", [])
)
' || fail "The existing workload access controls were changed or weakened."

kubectl get ippool.crd.projectcalico.org platform-ipv4-pool -o json | python3 -c '
import json
import sys

pool = json.load(sys.stdin)["spec"]
assert pool.get("cidr") == "10.245.0.0/16"
assert pool.get("disabled", False) is False
' || fail "The active workload address pool was changed instead of repairing the cluster."

catalog_ip="$(kubectl -n storefront get pod -l app=catalog \
  -o jsonpath='{.items[0].status.podIP}')"
[[ -n "$catalog_ip" ]] || fail "The catalog workload has no ready Pod IP."

kubectl -n storefront exec frontend -- \
  curl -fsS --connect-timeout 2 --max-time 5 "http://${catalog_ip}" >/dev/null || \
  fail "The catalog backend is not reachable directly from frontend."

kubectl -n storefront exec frontend -- \
  curl -fsS --connect-timeout 2 --max-time 5 http://catalog >/dev/null || \
  fail "The catalog Service is still unreachable from frontend."

if kubectl -n storefront exec reporting -- \
  curl -fsS --connect-timeout 2 --max-time 5 http://catalog >/dev/null 2>&1; then
  fail "reporting can reach catalog; the existing isolation boundary was weakened."
fi

proxy_config="$(kubectl -n kube-system get configmap kube-proxy \
  -o go-template='{{index .data "config.conf"}}')"
cluster_cidr="$(awk '$1 == "clusterCIDR:" {gsub(/"/, "", $2); print $2; exit}' \
  <<<"$proxy_config")"
detect_local_mode="$(awk '$1 == "detectLocalMode:" {gsub(/"/, "", $2); print $2; exit}' \
  <<<"$proxy_config")"
interface_name_prefix="$(awk '$1 == "interfaceNamePrefix:" {gsub(/"/, "", $2); print $2; exit}' \
  <<<"$proxy_config")"

[[ -n "$cluster_cidr" ]] || \
  fail "Application behavior is restored, but cluster networking remains inconsistent."

python3 - "$cluster_cidr" "$detect_local_mode" "$interface_name_prefix" <<'PY' || \
  fail "Application behavior is restored, but cluster networking remains inconsistent."
import ipaddress
import sys

configured = {
    ipaddress.ip_network(value.strip(), strict=False)
    for value in sys.argv[1].split(",")
    if value.strip()
}

cidr_repair = (
    sys.argv[2] == "ClusterCIDR"
    and configured == {ipaddress.ip_network("10.244.0.0/15")}
)
interface_repair = (
    sys.argv[2] == "InterfaceNamePrefix"
    and sys.argv[3] == "cali"
)

if not (cidr_repair or interface_repair):
    raise SystemExit(1)
PY

echo "Success: storefront connectivity is restored and reporting remains isolated."
