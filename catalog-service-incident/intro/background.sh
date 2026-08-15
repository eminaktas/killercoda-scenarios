#!/usr/bin/env bash
set -Eeuo pipefail

readonly kind_version="v0.31.0"
readonly kubernetes_version="v1.35.0"
readonly kind_node_image="kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f"
readonly calico_version="v3.32.1"
readonly assets_dir="/tmp/catalog-setup"
readonly ready_file="/tmp/.catalog-incident-ready"
readonly failed_file="/tmp/.catalog-incident-failed"
readonly error_file="/tmp/.catalog-incident-error"

work_dir="$(mktemp -d /tmp/kc-setup.XXXXXX)"
rm -f "$ready_file" "$failed_file" "$error_file"

cleanup_files() {
  rm -f \
    "$assets_dir/scenario.yaml" \
    "$assets_dir/kind-config.yaml" \
    "$assets_dir/calico-installation.yaml" \
    "$work_dir/kind" \
    "$work_dir/kubectl"
  rmdir "$assets_dir" "$work_dir" 2>/dev/null || true
}

mark_failed() {
  local line=${1:-unknown}
  local command=${2:-unknown}
  local status=${3:-1}
  trap - ERR
  printf 'Setup stopped at background.sh line %s (exit %s): %s\n' \
    "$line" "$status" "$command" >"$error_file"
  touch "$failed_file"
  exit "$status"
}

abort_setup() {
  local message=$1
  echo "$message" >&2
  mark_failed "$LINENO" "$message" 1
}

trap 'mark_failed "$LINENO" "$BASH_COMMAND" "$?"' ERR

for required_asset in \
  "$assets_dir/scenario.yaml" \
  "$assets_dir/kind-config.yaml" \
  "$assets_dir/calico-installation.yaml"; do
  if [[ ! -r "$required_asset" ]]; then
    abort_setup "Required scenario asset is unavailable: $required_asset"
  fi
done

for required_command in curl docker install python3 sha256sum timeout; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    abort_setup "Required host command is unavailable: $required_command"
  fi
done

case "$(uname -m)" in
  x86_64) binary_arch="amd64" ;;
  aarch64 | arm64) binary_arch="arm64" ;;
  *)
    abort_setup "Unsupported machine architecture: $(uname -m)"
    ;;
esac

download_verified() {
  local url=$1
  local checksum_url=$2
  local output=$3
  local expected

  curl --fail --location --silent --show-error \
    --retry 5 --retry-all-errors --output "$output" "$url"
  expected="$(curl --fail --location --silent --show-error \
    --retry 5 --retry-all-errors "$checksum_url" | awk '{print $1}')"
  printf '%s  %s\n' "$expected" "$output" | sha256sum --check --status
}

download_verified \
  "https://kind.sigs.k8s.io/dl/${kind_version}/kind-linux-${binary_arch}" \
  "https://kind.sigs.k8s.io/dl/${kind_version}/kind-linux-${binary_arch}.sha256sum" \
  "$work_dir/kind"
install -m 0755 "$work_dir/kind" /usr/local/bin/kind

download_verified \
  "https://dl.k8s.io/release/${kubernetes_version}/bin/linux/${binary_arch}/kubectl" \
  "https://dl.k8s.io/release/${kubernetes_version}/bin/linux/${binary_arch}/kubectl.sha256" \
  "$work_dir/kubectl"
install -m 0755 "$work_dir/kubectl" /usr/local/bin/kubectl

timeout 60 bash -c 'until docker info >/dev/null 2>&1; do sleep 2; done'
export KIND_EXPERIMENTAL_PROVIDER=docker

kind create cluster \
  --config "$assets_dir/kind-config.yaml" \
  --image "$kind_node_image" \
  --retain

kubectl create -f \
  "https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/v1_crd_projectcalico_org.yaml"
kubectl create -f \
  "https://raw.githubusercontent.com/projectcalico/calico/${calico_version}/manifests/tigera-operator.yaml"
kubectl wait --for=condition=Established \
  crd/installations.operator.tigera.io \
  crd/ippools.crd.projectcalico.org \
  --timeout=180s
kubectl create -f "$assets_dir/calico-installation.yaml"

kubectl wait --for=condition=Available \
  deployment/tigera-operator -n tigera-operator --timeout=180s
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl wait --for=condition=Available \
  deployment/calico-kube-controllers -n calico-system --timeout=180s
kubectl -n calico-system rollout status daemonset/calico-node --timeout=180s
kubectl -n kube-system rollout status daemonset/kube-proxy --timeout=180s

kubectl patch ippool.crd.projectcalico.org default-ipv4-ippool \
  --type=merge --patch '{"spec":{"disabled":true}}'
kubectl apply -f "$assets_dir/scenario.yaml"
kubectl -n storefront rollout status deployment/catalog --timeout=180s
kubectl -n storefront wait --for=condition=Ready pod/frontend pod/reporting \
  --timeout=180s
kubectl -n storefront wait \
  --for=jsonpath='{.endpoints[0].conditions.ready}'=true \
  endpointslice -l kubernetes.io/service-name=catalog --timeout=120s
kubectl get --raw=/readyz >/dev/null

frontend_ip="$(kubectl -n storefront get pod frontend \
  -o jsonpath='{.status.podIP}')"
catalog_ip="$(kubectl -n storefront get pod -l app=catalog \
  -o jsonpath='{.items[0].status.podIP}')"

python3 - "$frontend_ip" "$catalog_ip" <<'PY'
import ipaddress
import sys

pool = ipaddress.ip_network("10.245.0.0/16")
for value in sys.argv[1:]:
    if ipaddress.ip_address(value) not in pool:
        raise SystemExit(f"Unexpected workload address: {value}")
PY

kubectl -n storefront exec frontend -- \
  curl -fsS --connect-timeout 2 --max-time 5 "http://${catalog_ip}" >/dev/null

if kubectl -n storefront exec frontend -- \
  curl -fsS --connect-timeout 2 --max-time 5 http://catalog >/dev/null; then
  abort_setup "The broken ClusterIP path unexpectedly works."
fi

if kubectl -n storefront exec reporting -- \
  curl -fsS --connect-timeout 2 --max-time 5 http://catalog >/dev/null; then
  abort_setup "The reporting workload is not isolated."
fi

cleanup_files
touch "$ready_file"
trap - ERR
