# Docs-only correction — live validation (round 2)

Change under test: `docs/fm-test-portable-shards.md` (commit 916ad553), base 90cd351a.
Verified live against the real runner the doc points at, on the gate worktree.

## 1. The doc's pointer resolves to a working live command
```
$ bin/fm-test-run.sh --check-coverage
FM_TEST_COVERAGE ok total=251 parallel=24 parallel_max_ms=665545 parallel_imbalance_ms=2 parallel_unhinted=0 serial=211 serial_shards=9 serial_unhinted=10 serial_max_ms=1074843 serial_budget_ms=1200000 herdr=16
exit=0
```
The doc tells readers to read the lane size and unmeasured share from that
command instead of a copied count. It reports `serial=211` (lane size) and
`serial_unhinted=10` (unmeasured share), so the pointer is accurate.

## 2. The corrected coverage claim matches the live lane
```
$ bin/fm-test-run.sh --list --lane portable-serial | wc -l
211
$ # measured hint-table members
201
$ # unhinted serial members (pack on PORTABLE_SERIAL_DEFAULT_WEIGHT_MS)
tests/fm-backend-herdr-probe-timeout.test.sh
tests/fm-claim.test.sh
tests/fm-cline-harness.test.sh
tests/fm-cline-signals-live-e2e.test.sh
tests/fm-hold-reverify.test.sh
tests/fm-openhands-harness.test.sh
tests/fm-openhands-signals-live-e2e.test.sh
tests/fm-provider-lane-cap.test.sh
tests/fm-quota-wall-live-e2e.test.sh
tests/fm-watcher-continuity.test.sh
```
Hint table = 201 (upstream's measured set); live serial lane = 211; the 10
unhinted members are exactly the fork-only test files. This is what the doc
now says, and it confirms the old 'covers exactly all 24 parallel and 201
serial members' wording was stale for the fork.

## 3. Runner coverage-guard contract test (drives the real runner)
```
$ bash tests/fm-test-run.test.sh  # exit=0, all cases pass
ok - coverage guard bounds the unmeasured share and serial packing within twenty minutes
ok - portable shard union, disjointness, and coverage guard hold
ok - Herdr CI family-run step times out at 20 min under a 75 min job backstop
```

## 4. Refresh command's owner placeholder
The global `-R/--repo <OWNER/NAME>` flag is accepted after any gh-axi command,
so `gh-axi run download "$run" -R <owner>/firstmate --dir ...` is a valid
generalization of the former hardcoded upstream owner.
