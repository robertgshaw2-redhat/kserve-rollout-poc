#!/usr/bin/env bash
# Zero-downtime canary rollout for LLMInferenceService, one subcommand per step
# of https://kserve.github.io/website/docs/model-serving/generative-inference/llmisvc/canary-rollout
#
#   rollout.sh deploy-v1        step 1  bring up production
#   rollout.sh deploy-v2        step 2  add the canary at 9:1 (as written in the guide)
#   rollout.sh deploy-v2-safe   step 2  join the group only once Ready (does NOT help)
#   rollout.sh validate         step 3  compare the two versions
#   rollout.sh ramp <weight>    step 4  reweight the canary (9 => 50/50)
#   rollout.sh promote          step 5  stop v1, all traffic to v2
#   rollout.sh rollback         step 6  weight v2 down and restart v1
#   rollout.sh decommission     step 7  delete v1
#   rollout.sh status           group membership + weights
#   rollout.sh direct <v1|v2>   hit one version by name, bypassing weights
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

wait_ready() {
  log "waiting for $1 to be Ready"
  kubectl wait llmisvc "$1" -n "$NS" --for=condition=Ready --timeout="${2:-900s}"
}

cmd_deploy_v1() {
  kubectl apply -f "$MANIFEST_V1"
  wait_ready "$V1"
  log "routing-group label:"
  kubectl get llmisvc "$V1" -n "$NS" \
    -o jsonpath='{.metadata.labels.serving\.kserve\.io/routing-group}{"\n"}'
}

cmd_deploy_v2() {
  kubectl apply -f "$MANIFEST_V2"
  wait_ready "$V2"
  cmd_status
}

# Brings the canary up with no `route.group`/`weight`, waits for Ready, then
# patches it into the group.
#
# This DOES NOT avoid the outage, and is kept because proving that is the
# point: the controller groups members by spec.model.name, so the new pool
# lands in the publisher-path rules the moment the object exists, group
# declared or not. Measured 40,377 x 503 during the model load, then a clean
# join (3508/3508 OK). See results/findings.md.
cmd_deploy_v2_safe() {
  python3 "$ROOT/scripts/prewarm.py" detach "$MANIFEST_V2" | kubectl apply -f -
  wait_ready "$V2"
  log "canary is Ready and serving nothing -- now joining the group"
  kubectl patch llmisvc "$V2" -n "$NS" --type merge \
    -p "$(python3 "$ROOT/scripts/prewarm.py" patch "$MANIFEST_V2")"
  cmd_status
}

# Weights only move traffic; they do not restart pods. Patching one member is
# enough because the split is proportional across the whole group.
cmd_ramp() {
  local w="${1:?weight}"
  kubectl patch llmisvc "$V2" -n "$NS" --type merge \
    -p "{\"spec\":{\"router\":{\"route\":{\"weight\":$w}}}}"
  cmd_status
}

# `stop=true` frees the GPUs but keeps the object -- v1 stays rollback-ready.
cmd_promote() {
  kubectl annotate llmisvc "$V1" -n "$NS" serving.kserve.io/stop=true --overwrite
  cmd_status
}

cmd_rollback() {
  kubectl patch llmisvc "$V2" -n "$NS" --type merge \
    -p '{"spec":{"router":{"route":{"weight":1}}}}'
  kubectl annotate llmisvc "$V1" -n "$NS" serving.kserve.io/stop- 2>/dev/null || true
  wait_ready "$V1"
  cmd_status
}

# Step 3: compare the canary against production before ramping.
cmd_validate() {
  log "per-pod latency, $V1 (production)"
  version_latency "$V1"
  log "per-pod latency, $V2 (canary)"
  version_latency "$V2"
  cmd_status
}

cmd_decommission() { kubectl delete llmisvc "$V1" -n "$NS" --ignore-not-found; }

cmd_status() {
  log "group membership as the controller sees it"
  kubectl get llmisvc "$V2" -n "$NS" -o jsonpath='{.status.router.group}' 2>/dev/null \
    | python3 -m json.tool 2>/dev/null \
    || kubectl get llmisvc "$V1" -n "$NS" -o jsonpath='{.status.router.group}' | python3 -m json.tool
  log "weighted backendRefs in the HTTPRoute"
  # The weighted split lives on the publisher-path rules of each member's route.
  kubectl get httproute -n "$NS" -o json | python3 -c "
import sys, json
seen = set()
for r in json.load(sys.stdin)['items']:
    for rule in r['spec'].get('rules', []):
        refs = {b['name']: b.get('weight') for b in rule.get('backendRefs', [])}
        if len(refs) < 2:
            continue
        path = [m.get('path', {}).get('value') for m in rule.get('matches', [])]
        key = (r['metadata']['name'], tuple(sorted(refs.items())))
        if key in seen:
            continue
        seen.add(key)
        print(' ', r['metadata']['name'], refs, '  e.g.', path[0])
"
}

cmd_direct() {
  local name; name=$([ "${1:?v1|v2}" = v1 ] && echo "$V1" || echo "$V2")
  kubectl run curl-direct-$$ -n "$NS" --rm -i --restart=Never \
    --image=registry.access.redhat.com/ubi9/ubi-minimal:latest -- \
    curl -s -X POST "http://$GATEWAY/$NS/$name/v1/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL\",\"prompt\":\"The capital of France is\",\"max_tokens\":8}"
}

case "${1:-}" in
  deploy-v1)     cmd_deploy_v1 ;;
  deploy-v2)     cmd_deploy_v2 ;;
  deploy-v2-safe) cmd_deploy_v2_safe ;;
  validate)      cmd_validate ;;
  ramp)          cmd_ramp "${2:?weight}" ;;
  promote)       cmd_promote ;;
  rollback)      cmd_rollback ;;
  decommission)  cmd_decommission ;;
  status)        cmd_status ;;
  direct)        cmd_direct "${2:?v1|v2}" ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
