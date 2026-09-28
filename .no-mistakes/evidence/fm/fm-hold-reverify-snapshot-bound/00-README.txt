Live validation of the aged captain-call re-verification sweep
=============================================================

Every transcript here was produced by running bin/fm-hold-reverify.sh against a
disposable lab FM_HOME under /tmp whose data/backlog.md is a copy of the operator
home's real backlog (437 records, 108 captain holds, 47 aged >= 14 days, oldest
72 days - the shape the captain reported). The operator home itself was only read;
no fleet state, no tmux session and no credential store was touched, and the labs
were removed in this same turn. Forge reads went to github.com through the
product's own gh path, against real pull requests in kunchenguid/firstmate.

01-sweep-before-after.txt      the reported failure and the fix in one home: the
                               32386da script prints "could not read the aged-hold
                               projection" after its 5s bound; HEAD lists the aged
                               calls in 1.1s with the slow projection still present
02-docket-real-scale.json      the docket the sweep wrote at that fleet size
                               (ids masked, see the file's _redaction note)
03-real-forge-verdicts.txt     dead / still_live / not_a_decision / unestablishable
                               decided against real merged, open and closed-unmerged
                               pull requests; closed-unmerged never reads as dead
04-refusal-stays-loud.txt      the refusal survives: a failing projection and a
                               projection slower than the bound both still print it;
                               a tight FM_CHECK_TIMEOUT still lists the calls and
                               discloses the budget cut; a repeat sweep stays silent
05-watcher-standing-check.txt  arm, the shim the watcher validates, the watcher's own
                               dispatch path turning the sweep into a check: wake,
                               and disarm
06-report-only-never-closes.txt the backlog is byte-identical after the sweep; the
                               only writes are the docket and the cadence record
07-oldest-first-selection.txt  the 12 the bounded sweep examines are the 12 oldest of
                               the 47, with the 35 deferred disclosed
