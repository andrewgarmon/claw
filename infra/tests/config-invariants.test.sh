#!/usr/bin/env bash
# Tests for .github/scripts/config-invariants.py: the real openclaw.json passes, and changing any one
# listed setting fails naming it. Usage: bash infra/tests/config-invariants.test.sh
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO/.github/scripts" && exec python3 -I - "$REPO/openclaw.json" <<'PY'
import copy, json, sys
sys.dont_write_bytecode = True
import importlib.util as u
spec = u.spec_from_file_location("ci", "config-invariants.py"); ci = u.module_from_spec(spec); spec.loader.exec_module(ci)
real = json.load(open(sys.argv[1])); fails = 0

def expect(name, cfg, want):
    global fails
    bad = ci.check(cfg)
    ok = (want in bad) if want else bad == []
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": {bad}")); fails += not ok

def edit(path, fn):
    cfg = copy.deepcopy(real); *head, last = path.split("."); d = cfg
    for k in head: d = d[k]
    fn(d, last); return cfg

expect("the real openclaw.json passes", real, None)
for p in ci.EQUAL:
    expect(f"{p} changed", edit(p, lambda d, k: d.__setitem__(k, "changed")), p)
    expect(f"{p} removed", edit(p, lambda d, k: d.pop(k)), p)
for p, items in ci.CONTAINS.items():
    for t in items:
        expect(f"{p} without {t}", edit(p, lambda d, k: d[k].remove(t)), f"{p} is missing {t}")
for name in ["claw-tools", "duckduckgo", "acpx", "google"]:
    p = f"plugins.entries.{name}.hooks.allowPromptInjection"
    expect(f"{p} true", edit(f"plugins.entries.{name}", lambda d, k: d[k].setdefault("hooks", {}).__setitem__("allowPromptInjection", True)), p)
for name in ["claw-tools", "duckduckgo", "acpx"]:
    p = f"plugins.entries.{name}.hooks.allowPromptInjection"
    expect(f"{p} unset", edit(f"plugins.entries.{name}", lambda d, k: d[k].pop("hooks")), p)
print(); print("all config-invariants tests passed" if not fails else f"{fails} failed"); sys.exit(1 if fails else 0)
PY
