"""Split a member manifest into (a) an ungrouped copy and (b) its group patch.

Used by `rollout.sh deploy-v2-safe` to test whether holding a version out of the
routing group until it is Ready avoids the admission outage. It does not --
members are grouped by spec.model.name, not by route.group. See
results/findings.md.

  prewarm.py detach <manifest>   -> manifest on stdout with route.group/weight removed
  prewarm.py patch  <manifest>   -> the merge patch that joins the group
"""
import sys, json, yaml

mode, path = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(path))
route = doc["spec"]["router"]["route"]

if mode == "patch":
    print(json.dumps({"spec": {"router": {"route": {
        "group": route["group"], "weight": route["weight"]}}}}))
else:
    route.pop("group", None)
    route.pop("weight", None)
    print(yaml.safe_dump(doc, sort_keys=False))
