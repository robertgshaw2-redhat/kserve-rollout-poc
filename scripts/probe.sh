#!/usr/bin/env bash
# Continuous traffic probe: proves the rollout is zero-downtime and measures
# where traffic actually landed.
#
#   probe.sh start          launch the in-cluster load generator
#   probe.sh mark <label>   timestamp a rollout step (and flush the pod log)
#   probe.sh split <label>  snapshot per-version request counters
#   probe.sh report         downtime + per-phase traffic split
#   probe.sh stop           tear the load generator down
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TIMELINE="$RESULTS/timeline.tsv"
SPLITS="$RESULTS/splits.tsv"

cmd_start() {
  # Version-agnostic publisher path: the client never names v1 or v2.
  local url="http://$GATEWAY/publishers/$NS/models/$MODEL/v1/completions"
  log "probe target: $url"
  log "status address: $(kubectl get llmisvc "$V1" -n "$NS" \
    -o jsonpath='{.status.addresses[?(@.name=="internal-model-routing")].url}')"
  sed -e "s|__URL__|$url|" -e "s|__MODEL__|$MODEL|" "$ROOT/manifests/loadgen.yaml" \
    | kubectl apply -f -
  kubectl rollout status deploy/rollout-probe -n "$NS" --timeout=120s
  : > "$TIMELINE"; : > "$SPLITS"
  cmd_mark "probe-start"
}

# Container logs rotate at ~10MB, which a multi-hour probe blows through in
# minutes. Every mark flushes what is still in the ring buffer into probe.log.
cmd_flush() {
  kubectl logs deploy/rollout-probe -n "$NS" --tail=-1 >> "$RESULTS/probe.raw" 2>/dev/null || true
  sort -un -k1,1 "$RESULTS/probe.raw" > "$RESULTS/probe.log"
}

cmd_mark() {
  cmd_flush
  printf '%s\t%s\n' "$(now_ms)" "$1" | tee -a "$TIMELINE"
}

cmd_split() {
  local a b
  a=$(version_requests "$V1"); b=$(version_requests "$V2" || echo 0)
  printf '%s\t%s\t%s\t%s\n' "$(now_ms)" "$1" "$a" "$b" | tee -a "$SPLITS"
}

cmd_report() {
  cmd_flush
  python3 "$ROOT/scripts/report.py" "$RESULTS" | tee "$RESULTS/report.txt"
}

cmd_stop() { kubectl delete deploy/rollout-probe -n "$NS" --ignore-not-found; }

case "${1:-}" in
  start)  cmd_start ;;
  mark)   cmd_mark "${2:?label}" ;;
  flush)  cmd_flush ;;
  split)  cmd_split "${2:?label}" ;;
  report) cmd_report ;;
  stop)   cmd_stop ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
