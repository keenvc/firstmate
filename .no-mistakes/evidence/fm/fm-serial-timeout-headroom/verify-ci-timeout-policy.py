#!/usr/bin/env python3
"""Semantic check of the CI three-tier timeout policy in .github/workflows/ci.yml.

GitHub Actions is the only real consumer of this declarative artifact, so this
script parses the workflow into a typed model and asserts the *meaning* the
policy owns: tier membership, one shared value per tier, three distinct
job-level values, and the Herdr step tripwire below its job backstop.

Usage: verify-ci-timeout-policy.py <ci.yml> <docs/fm-test-portable-shards.md>
"""
import sys
import yaml

FAST = ["test-coverage", "invariants", "tests-timing-aggregate"]
NORMAL = [
    "lint",
    "tests-portable-parallel-1",
    "tests-portable-parallel-2",
    "tests-portable-serial",
    "macos-stock-bash",
]
HEAVY = ["tests-herdr"]

EXPECTED_NORMAL = 60


def main(ci_path, docs_path):
    doc = yaml.safe_load(open(ci_path))
    jobs = doc["jobs"]
    print("job                              timeout-minutes")
    for name, job in jobs.items():
        print(f"  {name:32s} {job.get('timeout-minutes')!r}")

    # Every job carries a finite positive timeout.
    for name, job in jobs.items():
        t = job.get("timeout-minutes")
        assert isinstance(t, int) and t > 0, f"{name}: no finite timeout ({t!r})"

    # Tiers partition the job inventory exactly once.
    tiered = FAST + NORMAL + HEAVY
    assert len(tiered) == len(set(tiered)), "a job is listed in more than one tier"
    assert set(tiered) == set(jobs), (
        f"tiers and jobs disagree: jobs={sorted(jobs)} tiers={sorted(tiered)}"
    )

    def shared(tier, names):
        values = {jobs[n]["timeout-minutes"] for n in names}
        assert len(values) == 1, f"{tier} tier jobs must share one timeout: {values}"
        return values.pop()

    fast = shared("fast", FAST)
    normal = shared("normal", NORMAL)
    heavy = shared("heavy", HEAVY)

    assert 5 <= fast <= 10, f"fast tier out of 5-10 band: {fast}"
    assert normal > fast, f"normal ({normal}) must exceed fast ({fast})"
    assert normal == EXPECTED_NORMAL, (
        f"normal tier must be the single {EXPECTED_NORMAL}-minute shared budget, got {normal}"
    )
    assert heavy > normal, f"heavy ({heavy}) must exceed normal ({normal})"
    assert 60 <= heavy <= 75, f"heavy backstop out of 60-75 band: {heavy}"

    distinct = {jobs[n]["timeout-minutes"] for n in jobs}
    assert len(distinct) == 3, f"expected exactly 3 distinct job timeouts, got {sorted(distinct)}"

    steps = jobs["tests-herdr"]["steps"]
    run_idx = next(i for i, s in enumerate(steps) if s.get("id") == "run-real-herdr-family")
    clean_idx = next(
        i for i, s in enumerate(steps) if s.get("id") == "cleanup-herdr-lab-sessions"
    )
    step_timeout = steps[run_idx]["timeout-minutes"]
    assert clean_idx > run_idx, "herdr teardown must follow the family-run step"
    assert steps[clean_idx].get("if", "").strip() == "always()", (
        "herdr teardown must run under always()"
    )
    assert step_timeout == 20, f"herdr family-run step must be 20, got {step_timeout}"
    assert step_timeout < heavy, f"herdr step ({step_timeout}) must be below job backstop ({heavy})"

    print()
    print(f"fast={fast} normal={normal} heavy={heavy} distinct_job_values={sorted(distinct)}")
    print(f"herdr family-run step={step_timeout} under job backstop={heavy}")
    print(
        "POLICY OK: every job in one tier; normal tier shares the "
        f"{normal}-minute budget; heavy {heavy} > normal {normal}."
    )

    docs = open(docs_path).read()
    assert "| Normal |" in docs, "docs tier table missing Normal row"
    normal_row = next(l for l in docs.splitlines() if l.startswith("| Normal |"))
    assert f"{EXPECTED_NORMAL} minutes" in normal_row, (
        f"docs Normal row does not state {EXPECTED_NORMAL} minutes: {normal_row}"
    )
    assert "cite observed evidence of lost headroom" in docs, (
        "docs policy prose does not name the evidence bar for raising a bound"
    )
    print("DOCS OK: tier table states 60 minutes and the prose names the evidence bar.")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
