# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-latest`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

The proven-isolated candidate set remains the 24-script concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The 2026-09-14 placement refresh uses completed script measurements in [CI run 34837015817](https://github.com/HelloWorldSungin/firstmate/actions/runs/34837015817).
Its first parallel lane reached the unchanged ten-minute job limit after five completed scripts, with the enlarged hold and merge suites accounting for 504 seconds together.
The second parallel lane completed successfully.
The six scripts not completed before the first lane was cancelled retain the earlier passing measurements from [CI run 34800278334](https://github.com/HelloWorldSungin/firstmate/actions/runs/34800278334), shown explicitly below.
These measurements change placement, not isolation eligibility or execution deadlines.

| duration_ms | script | Measurement |
|---:|---|---|
| 305369 | `tests/fm-captain-hold-lifecycle.test.sh` | CI completed script |
| 209643 | `tests/fm-lint.test.sh` | CI completed script |
| 198766 | `tests/fm-pr-merge.test.sh` | CI completed script |
| 157536 | `tests/fm-test-run.test.sh` | CI completed script |
| 41660 | `tests/fm-crew-state.test.sh` | CI completed script |
| 30805 | `tests/fm-arm-pretool-check.test.sh` | CI completed script |
| 29237 | `tests/fm-x-mode.test.sh` | CI completed script |
| 27380 | `tests/fm-backend-herdr.test.sh` | CI completed script |
| 23099 | `tests/fm-brief.test.sh` | CI completed script |
| 16799 | `tests/fm-cd-pretool-check.test.sh` | CI completed script |
| 7584 | `tests/fm-send-strict.test.sh` | CI completed script |
| 6983 | `tests/fm-grok-harness.test.sh` | Previous recorded measurement |
| 6351 | `tests/fm-herdr-lab.test.sh` | Previous recorded measurement |
| 4883 | `tests/fm-send-popup-settle.test.sh` | CI completed script |
| 4644 | `tests/fm-composer-lib.test.sh` | CI completed script |
| 4220 | `tests/fm-pi-primary-types.test.sh` | Previous recorded measurement |
| 3832 | `tests/fm-review-diff.test.sh` | Previous recorded measurement |
| 2505 | `tests/fm-spawn-batch.test.sh` | CI completed script |
| 2453 | `tests/fm-tmux-submit-busy.test.sh` | CI completed script |
| 2049 | `tests/fm-composer-ghost.test.sh` | Previous recorded measurement |
| 1834 | `tests/fm-send-settle.test.sh` | Previous recorded measurement |
| 906 | `tests/fm-ensure-agents-md.test.sh` | CI completed script |
| 342 | `tests/fm-supervision-instructions.test.sh` | CI completed script |
| 171 | `tests/fm-transition-lib.test.sh` | CI completed script |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap and its rationale are owned by [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The hints are the slowest measurement of each of the lane's 139 scripts across the `fm-test-timing-portable-serial-*` artifacts of three green CI runs on 2026-09-01, [33558082172](https://github.com/kunchenguid/firstmate/actions/runs/33558082172), [33523597838](https://github.com/kunchenguid/firstmate/actions/runs/33523597838), and [33463326167](https://github.com/kunchenguid/firstmate/actions/runs/33463326167).
Shared scripts use those upstream per-script maxima; fork-only scripts retain their existing measured hints from run [32191955185](https://github.com/HelloWorldSungin/firstmate/actions/runs/32191955185).
The round also includes upstream's retained native-Windows measurement for `tests/fm-pi-windows-shell-invocation.test.sh` and its new live-guard weights.
The 2026-09-14 refresh takes the maximum of those retained hints and completed passing-script measurements from fork CI runs [34802687283](https://github.com/HelloWorldSungin/firstmate/actions/runs/34802687283) and [34804089007](https://github.com/HelloWorldSungin/firstmate/actions/runs/34804089007).
The latter's serial lane 5 reached its unchanged 20-minute cap after 16 passing scripts; its completed `FM_TEST_END` records are included explicitly because cancellation prevented a timing artifact.
Before the next upstream prefix was included, these runs provided passing measurements for 200 of the 201 serial scripts; `tests/fm-test-isolation-proof.test.sh` retains its earlier 2567 ms hint, with its corrected assertion passing locally.
The next prefix takes the maximum of each retained fork hint and the upstream endpoint's existing hint.
Taking maxima preserves native-Windows measurements and earlier slow-run evidence rather than replacing them with portable gate-skip durations.
A script with no hint receives `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS`; the runner's coverage output reports that unmeasured share.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
`bin/fm-test-run.sh --check-coverage` now reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so hint drift fails the coverage guard instead of silently pushing one shard into its job cap.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for that bound to trip.

The fork retains eight portable serial shards and its 480-second per-script bound.
`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size, shard composition, and balance rather than a copied table.
Run 34342484144 observed a shard reach about 20 minutes of passing work, so the 30-minute job cap keeps meaningful hang-tripwire margin for job setup and runner-speed spread.

The watcher triage cases are split into core and wait/decision scripts with one shared fixture owner in `tests/watch-triage-helpers.sh`.
All 125 original cases remain in exactly one script, with compatible new upstream progress and declared-deadline cases added beside them.
Their initial passing local measurements were 160205 ms and 191775 ms after CI reached the unchanged 480-second combined-script limit while still passing cases.
The refreshed CI hints are 236467 ms for core and 292716 ms for waits.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" -R HelloWorldSungin/firstmate --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard uploads no artifact, so pick runs where every serial shard is green or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and together cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | See [CI workflow](../.github/workflows/ci.yml) | The workflow owns the parallel cap rationale and its evidence limits. |
| portable serial 1-8 | job `timeout-minutes: 30` | Current runners can take about 20 minutes; the 30-minute cap remains a hang tripwire while leaving margin for job setup and runner-speed spread. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are intended as hang tripwires; a passing coverage guard does not establish a healthy job duration.
`.github/workflows/ci.yml` owns the exact numbers.

Inside each lane, `bin/fm-test-run.sh` applies its own default per-script bound, so a hung script usually turns red with per-script attribution before the job cap cancels the lane; its `--help` owns that bound's value and opt-out, and the rationale beside `DEFAULT_PER_SCRIPT_TIMEOUT_SECS` owns the per-lane margin arithmetic.
Neither portable lane has room to spare, because a hung script spends the bound instead of its own healthy slot.
On the slowest estimated serial shard, replacing its average script with the 480-second bound puts script time around 21 minutes, within the 30-minute cap before checkout and bootstrap overhead.
The healthy estimate retains roughly sixteen minutes for setup and runner-speed variation.
The portable parallel cap is tighter still: the same arithmetic already lands past its 10-minute cap before setup, so expect the job timeout rather than per-script attribution when a script hangs there.
On the required Herdr lane the bound has the thinnest margin over its slowest measured script, so a healthy but unusually slow Herdr end-to-end script can turn red as `exit=124`; that margin is accepted rather than widened, tracked in `HelloWorldSungin/firstmate#256`.
