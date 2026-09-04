# Shared settings + helpers for the rollout POC.
set -euo pipefail

NS="${NS:-robshaw-dev}"
GROUP="${GROUP:-gemma-4-rollout}"
MODEL="${MODEL:-gemma-4-rollout}"
V1="${V1:-gemma-4-rollout-v1}"
V2="${V2:-gemma-4-rollout-v2}"
MANIFEST_V1="${MANIFEST_V1:-}"
MANIFEST_V2="${MANIFEST_V2:-}"
GATEWAY="${GATEWAY:-inference-gateway-istio.redhat-ods-applications.svc.cluster.local}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="$ROOT/results"
mkdir -p "$RESULTS"
: "${MANIFEST_V1:=$ROOT/manifests/v1.yaml}"
: "${MANIFEST_V2:=$ROOT/manifests/v2.yaml}"

# BSD date has no %3N, so milliseconds come from python.
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Sum vllm:request_success_total across every model pod of one LLMISVC.
# Scraped straight off the pods: the gateway does not expose /metrics, and
# per-version counters are what prove where the traffic actually landed.
version_requests() {
  local name="$1" total=0 pod n
  for pod in $(kubectl get pods -n "$NS" \
        -l "app.kubernetes.io/name=$name,kserve.io/component=workload" \
        --field-selector status.phase=Running -o name 2>/dev/null); do
    n=$(kubectl exec -n "$NS" "${pod#pod/}" -c main -- python3 -c "
import ssl, urllib.request
ctx = ssl._create_unverified_context()
body = urllib.request.urlopen('https://localhost:8000/metrics', context=ctx, timeout=10).read().decode()
print(sum(float(l.rsplit(' ', 1)[1]) for l in body.splitlines()
          if l.startswith('vllm:request_success_total{')))
" 2>/dev/null || echo 0)
    total=$(python3 -c "print(int(float('$total') + float('${n:-0}')))")
  done
  echo "$total"
}

# Per-version latency, read from the vLLM histograms on each pod.
# The guide runs this comparison in Prometheus; scraping the pods directly
# keeps the POC self-contained on a cluster without a query endpoint.
version_latency() {
  local name="$1" pod
  for pod in $(kubectl get pods -n "$NS" \
        -l "app.kubernetes.io/name=$name,kserve.io/component=workload" \
        --field-selector status.phase=Running -o name 2>/dev/null); do
    kubectl exec -n "$NS" "${pod#pod/}" -c main -- python3 -c "
import ssl, urllib.request
ctx = ssl._create_unverified_context()
body = urllib.request.urlopen('https://localhost:8000/metrics', context=ctx, timeout=10).read().decode()
acc = {}
for line in body.splitlines():
    for m in ('vllm:time_to_first_token_seconds', 'vllm:e2e_request_latency_seconds'):
        for suffix in ('_sum', '_count'):
            if line.startswith(m + suffix + '{'):
                acc[m + suffix] = acc.get(m + suffix, 0.0) + float(line.rsplit(' ', 1)[1])
def mean(m):
    c = acc.get(m + '_count', 0)
    return acc.get(m + '_sum', 0) / c if c else float('nan')
print('%-52s ttft_mean=%.3fs  e2e_mean=%.3fs  n=%d' % (
    '$name/' + '${pod#pod/}'.rsplit('-', 1)[-1],
    mean('vllm:time_to_first_token_seconds'),
    mean('vllm:e2e_request_latency_seconds'),
    acc.get('vllm:e2e_request_latency_seconds_count', 0)))
" 2>/dev/null
  done
}
