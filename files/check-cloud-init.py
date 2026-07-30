#!/usr/bin/env python3
# files/check-cloud-init.py
import json, subprocess, sys

# exit code from status --format json is unreliable (2 = degraded, not error)
# capture output regardless of exit code
result = subprocess.run(
    ["sudo", "cloud-init", "status", "--format", "json"],
    capture_output=True, text=True
)

try:
    d = json.loads(result.stdout)
except json.JSONDecodeError:
    print(f"Failed to parse cloud-init status output:\n{result.stdout}")
    sys.exit(1)

v1 = d.get("v1", d)
stages = ["init-local", "init", "modules-config", "modules-final"]
errors = [(s, e) for s in stages for e in v1.get(s, {}).get("errors", [])]

if errors:
    for stage, err in errors:
        print(f"FAIL [{stage}]: {err}")
    sys.exit(1)

print("cloud-init ok — no errors in any stage")