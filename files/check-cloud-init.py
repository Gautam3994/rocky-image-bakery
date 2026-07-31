#!/usr/bin/env python3
# files/check-cloud-init.py
import json, subprocess, sys

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
status = v1.get("extended_status") or v1.get("status")
detail = v1.get("detail", "n/a")

stages = ["init-local", "init", "modules-config", "modules-final"]
errors = [(s, e) for s in stages for e in v1.get(s, {}).get("errors", [])]
errors += [("top-level", e) for e in v1.get("errors", [])]

def flatten_recoverable(re_dict, label):
    return [(label, level, msg) for level, msgs in re_dict.items() for msg in msgs]

recoverable = flatten_recoverable(v1.get("recoverable_errors", {}), "top-level")
for s in stages:
    recoverable += flatten_recoverable(v1.get(s, {}).get("recoverable_errors", {}), s)

print(f"status: {status}")
print(f"detail: {detail}")

# Hard errors, or anything other than done/degraded-done, fails the build.
if errors or status not in ("done", "degraded done"):
    for stage, err in errors:
        print(f"ERROR [{stage}]: {err}")
    print(f"FAIL: cloud-init status is '{status}'")
    sys.exit(1)

# degraded done = a WARNING-level recoverable_error was logged.
# Print for visibility but don't fail the build on it alone -- matches
# upstream cloud-init's own stance after they walked back exit code 2
# for exactly this class of warning.
for stage, level, msg in recoverable:
    print(f"{level} [{stage}]: {msg}")

print(f"cloud-init ok — status '{status}', no hard errors")