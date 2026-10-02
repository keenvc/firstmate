# Doc claims vs. live evidence — docs/fm-test-portable-shards.md (commit 916ad553)

All commands run from the gate worktree at 916ad553.

## Doc claim (line 16)
"This fork's serial lane carries additional fork-only members that no upstream
run measured, so each of them packs on the `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS`
default ... read the current lane size and unmeasured share from
`bin/fm-test-run.sh --check-coverage` rather than from a count copied here."

## Live evidence

```
$ bin/fm-test-run.sh --check-coverage
FM_TEST_COVERAGE ok total=251 parallel=24 parallel_max_ms=665545 parallel_imbalance_ms=2 parallel_unhinted=0 serial=211 serial_shards=9 serial_unhinted=10 serial_max_ms=1074843 serial_budget_ms=1200000 herdr=16
exit=0
```

The `serial=` field is the live lane size and `serial_unhinted=` is the
unmeasured share the doc points readers at. Both are reported, so the pointer
is accurate.

## Cross-check of the numbers

| Doc statement | Live value | Source |
|---|---|---|
| "all 24 parallel members" | `parallel=24` | `--check-coverage` |
| "the 201 serial members the lane held upstream" | 201 entries in `portable_serial_weight_hints` | script hint table |
| fork serial lane carries additional fork-only members | `serial=211` (211 - 201 = 10 extra) | `--list --lane portable-serial` |
| each fork-only member packs on the default | `serial_unhinted=10` | `--check-coverage` |
| `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default exists | `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS=45000` | `bin/fm-test-run.sh` |

The 10 unmeasured (default-weighted) members are exactly the fork-only test
files added on this fork: fm-backend-herdr-probe-timeout, fm-claim,
fm-cline-harness, fm-cline-signals-live-e2e, fm-hold-reverify,
fm-openhands-harness, fm-openhands-signals-live-e2e, fm-provider-lane-cap,
fm-quota-wall-live-e2e, fm-watcher-continuity.

## Refresh-command placeholder (line 82)

Before: `gh-axi run download "$run" -R kunchenguid/firstmate --dir ...`
After:  `gh-axi run download "$run" -R <owner>/firstmate --dir ...`

The hardcoded upstream owner in the refresh command is generalized; the
remaining `kunchenguid/firstmate` occurrences in the doc are historical CI run
and PR links that are correct to keep.
