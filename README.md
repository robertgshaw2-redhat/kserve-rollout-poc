# Zero-downtime rollout POC -- KServe LLMInferenceService canary

Runs the canary rollout from the KServe guide end to end against a live cluster,
with a client hammering the endpoint the whole time, and measures whether it is
actually zero-downtime.

Guide: https://kserve.github.io/website/docs/model-serving/generative-inference/llmisvc/canary-rollout

**Result: the traffic-shifting half is zero-downtime and works exactly as
documented. Admitting the canary in the first place is not** -- it took the
whole inference gateway down for 280s, including unrelated models. Numbers,
isolation experiments and the two workarounds that failed are in
[results/findings.md](results/findings.md).

## What is here

```
manifests/
  v1.yaml        production member of routing group `gemma-4-rollout`, weight 9
  v2.yaml        canary member, same model name, weight 1, different vLLM batching config
  loadgen.yaml   in-cluster 4-worker client on the version-agnostic publisher path
scripts/
  rollout.sh     one subcommand per step of the guide
  probe.sh       start/mark/split/report the traffic probe
  prewarm.py     splits a member manifest into an ungrouped copy + its join patch
  report.py      turns the probe log into downtime + per-phase traffic split
  lib.sh         settings; per-version request counts and latency from vLLM metrics
results/         captured output of the run described in findings.md
```

The two versions differ only in `VLLM_ADDITIONAL_ARGS` -- a serving-config
rollout. Bumping the `image` tag instead is the same procedure and the same
manifest line; nothing else changes.

## Running it

Needs a cluster with the LLMInferenceService controller, a Gateway API
implementation with weighted `backendRef` support, and 3 spare GPUs.
Namespace, names and gateway host are the defaults at the top of `scripts/lib.sh`
and are all environment-overridable.

```bash
./scripts/rollout.sh deploy-v1      # step 1: production, weight 9
./scripts/probe.sh   start          # continuous client, from here on it never stops

./scripts/probe.sh   mark "canary"  # timestamps a phase boundary in the report
./scripts/probe.sh   split before
./scripts/rollout.sh deploy-v2      # step 2: canary at 9:1  -- THIS IS THE OUTAGE
./scripts/probe.sh   split after

./scripts/rollout.sh validate       # step 3: per-version TTFT / e2e latency
./scripts/rollout.sh ramp 9         # step 4: 50/50
./scripts/rollout.sh promote        # step 5: stop v1, v2 takes everything
./scripts/rollout.sh rollback       # step 6: v2 back to weight 1, restart v1
./scripts/rollout.sh decommission   # step 7: delete v1

./scripts/probe.sh   report         # downtime + measured split per phase
./scripts/probe.sh   stop
```

`rollout.sh status` prints group membership as the controller sees it plus the
weighted `backendRef`s it wrote into the HTTPRoutes. `rollout.sh direct v1|v2`
hits one version by name, bypassing weights.

## How the measurement works

The gateway VIP is not routable from a laptop, so the client runs in-cluster as
`deploy/rollout-probe` and logs `<epoch_ms> <worker> <http_code> <seconds>` per
request. Downtime comes from those status codes; the traffic split comes from
`vllm:request_success_total` scraped off each version's pods, because the
gateway does not expose per-version counters and the model servers are the only
place that knows where a request really landed. Container logs rotate at ~10MB,
which this probe fills in minutes -- `probe.sh mark` flushes the ring buffer to
`results/probe.log` on every phase boundary.

`rollout.sh validate` is the local stand-in for the guide's Prometheus query: it
reads the vLLM TTFT and e2e-latency histograms straight off the pods, so the
comparison works on a cluster with no query endpoint wired up.

## Reproducing the outage cheaply

The failure needs no GPU and no model load -- any member with zero Ready
endpoints does it. Add `nodeSelector: {rollout-poc/does-not-exist: "true"}` to a
copy of `v2.yaml`, apply it, and the publisher path goes to 100% 503 within a
minute; delete it and traffic returns immediately. That is the two-minute
repro to hand to whoever owns the gateway.
