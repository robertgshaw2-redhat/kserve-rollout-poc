# What the POC measured

Cluster `statler`, namespace `robshaw-dev`, KServe LLMInferenceService v1alpha2
(RHOAI 3.5.0 configs), Istio inference-gateway with Gateway API InferencePools.
Model: `RedHatAI/gemma-4-12B-it-FP8-Dynamic` served under the group model name
`gemma-4-rollout`, vLLM `quay.io/vllm/automation-vllm:0.24.0_rhaiv.12`, 1 GPU
per replica. v1 = 2 replicas / `--max-num-seqs 256`, v2 = 1 replica /
`--max-num-seqs 64 --max-num-batched-tokens 8192`.

A 4-worker client hit the version-agnostic publisher path continuously through
every step. Traffic attribution comes from `vllm:request_success_total` scraped
off each version's pods, so the split is what the model servers actually saw,
not what the manifests asked for.

## The weighting mechanism works exactly as documented

| step | weights | measured split |
|---|---|---|
| canary added | v1=9, v2=1 | 90% / 10% |
| ramped | v1=9, v2=9 | 49% / 51% |
| v1 stopped | v1 stopped, v2=9 | 0% / 100% |
| rolled back | v1=9, v2=1 | 89% / 11% |

Reweighting is genuinely zero-downtime: `kubectl patch` of `route.weight`
restarted no pods, shifted traffic within seconds, and cost 0 failed requests
out of 5195 in the 50/50 window. Throughput held at ~26 req/s and p50 latency
at 0.15s across every reweight. `status.router.group` lists all members
symmetrically, and `serving.kserve.io/stop=true` released v1's GPUs while
keeping the object rollback-ready with its weight preserved (34 requests were
lost at that moment: 5x503 + 29x500).

Rollback took 9m57s end to end, all of it v1's pods reloading the model --
weights themselves moved instantly.

## The rollout is not zero-downtime as the guide writes it

**Creating the canary caused 280 seconds of 100% failure**: 69,169 consecutive
503s from 25s after `kubectl apply -f v2.yaml` until v2's pod went Ready
(17:19:48Z -> 17:24:28Z, v2 Ready at 17:24:34Z). Not 10% of traffic matching
v2's weight -- all of it.

Three follow-up experiments isolated the trigger. Each used a member pinned to
an unschedulable `nodeSelector`, so it stayed `Pending` forever and cost no GPU.

1. **Any group member with zero Ready endpoints fails the whole route.** With
   v1 (2 healthy replicas) and v2 (1 healthy replica) serving fine, adding a
   third member that could never schedule took the publisher path to 100% 503
   within a minute. Deleting it restored traffic immediately. It is not about
   model loading -- an empty pool is enough.

2. **The rejection happens before upstream selection.** Envoy access logs for
   the failed requests show no upstream host (`"-"`), 0 upstream duration, and
   an empty response-flag field, on requests whose selected cluster was the
   *healthy* `gemma-4-rollout-v1-inference-pool`. Consistent with the endpoint
   picker rejecting the request rather than a "no healthy upstream" failure.

3. **The blast radius is the gateway, not the group.** During that outage the
   name-scoped path of the healthy v1 (`/robshaw-dev/gemma-4-rollout-v1/...`)
   also returned 503, and so did an unrelated LLMInferenceService in the same
   namespace on the same gateway (`gemma-4-downstream`, different model name,
   different pools) -- 5/5 requests 503, back to 200 within 40s of deleting the
   unready member.

## Two obvious workarounds that do not work

- **Deploy the canary outside the group first, patch it in once Ready.**
  Implemented as `rollout.sh deploy-v2-safe`. It still produced 40,377 503s
  during the model load. The controller groups members by `spec.model.name`,
  not by `spec.router.route.group`: the HTTPRoute publisher rules picked up the
  new inference pool the moment the object was created, group declared or not.
  Joining the group afterwards was clean -- 3508/3508 requests 200.
- **`serving.kserve.io/model-based-routing-enabled: "false"` via
  `spec.annotations`.** Accepted by the API, did not restart pods, and did not
  remove the member's pool from the publisher rules.

## Operational conclusion

Weight-shifting is safe and instant; **admitting a new version is not**. On this
stack a canary must be brought up when a gateway-wide outage for the duration of
its model load is acceptable, or the whole inference gateway needs to be split
so that a loading pool cannot take down unrelated services. Steps 3 through 7 of
the guide -- validate, ramp, promote, roll back, decommission -- are all safe to
run against live traffic exactly as written.

Worth filing upstream: an InferencePool with zero Ready endpoints should be
skipped by the endpoint picker, not fail requests bound for its siblings.
