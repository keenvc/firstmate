import sys, yaml
doc = yaml.safe_load(open(".github/workflows/ci.yml"))
jobs = doc["jobs"]
normal = {"lint","tests-portable-parallel-1","tests-portable-parallel-2","tests-portable-serial","macos-stock-bash"}
fast = {"test-coverage","invariants","tests-timing-aggregate"}
heavy = {"tests-herdr"}
assert set(jobs) == normal|fast|heavy, set(jobs) ^ (normal|fast|heavy)
vals = {}
for name, job in jobs.items():
    vals[name] = job.get("timeout-minutes")
print("job timeouts:", {k: vals[k] for k in sorted(vals)})
assert all(vals[n] == 60 for n in normal), {n: vals[n] for n in normal}
assert all(vals[n] == 5 for n in fast), {n: vals[n] for n in fast}
assert vals["tests-herdr"] == 75, vals["tests-herdr"]
distinct = sorted(set(vals.values()))
print("distinct job-level timeout values:", distinct)
assert distinct == [5, 60, 75], distinct
# Resolve the Pi install commands in every job step (semantic, not substring on the raw file).
installs = []
for name, job in jobs.items():
    for step in job.get("steps", []):
        run = step.get("run", "")
        for line in run.splitlines():
            line = line.strip()
            if line.startswith("npm install -g @earendil-works/pi-coding-agent"):
                installs.append((name, line))
print("pi install commands:")
for name, line in installs:
    print(f"  {name}: {line}")
assert len(installs) == 2, installs
assert all(line.endswith("@0.99.2") for _, line in installs), installs
assert not any(line.endswith("pi-coding-agent") for _, line in installs), "an unpinned install remains"
print("PASS: normal tier 60m across all 5 jobs; distinct values 5/60/75; both pi installs pinned @0.99.2")
