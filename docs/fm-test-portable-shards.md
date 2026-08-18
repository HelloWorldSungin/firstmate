# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-07-29 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 52939 | `tests/fm-x-mode.test.sh` |
| 48294 | `tests/fm-backend-herdr.test.sh` |
| 46788 | `tests/fm-arm-pretool-check.test.sh` |
| 34207 | `tests/fm-cd-pretool-check.test.sh` |
| 30771 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 25365 | `tests/fm-crew-state.test.sh` |
| 15674 | `tests/fm-test-run.test.sh` |
| 15422 | `tests/fm-herdr-lab.test.sh` |
| 9065 | `tests/fm-composer-ghost.test.sh` |
| 8564 | `tests/fm-pr-merge.test.sh` |
| 6251 | `tests/fm-grok-harness.test.sh` |
| 5644 | `tests/fm-send-popup-settle.test.sh` |
| 5237 | `tests/fm-lint.test.sh` |
| 4816 | `tests/fm-tmux-submit-busy.test.sh` |
| 2945 | `tests/fm-pi-primary-types.test.sh` |
| 2911 | `tests/fm-send-settle.test.sh` |
| 2875 | `tests/fm-review-diff.test.sh` |
| 2747 | `tests/fm-send-strict.test.sh` |
| 2224 | `tests/fm-brief.test.sh` |
| 855 | `tests/fm-spawn-batch.test.sh` |
| 703 | `tests/fm-supervision-instructions.test.sh` |
| 581 | `tests/fm-ensure-agents-md.test.sh` |
| 248 | `tests/fm-transition-lib.test.sh` |
| 64 | `tests/fm-composer-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 162436 ms (~162.4 s) |
| `portable-parallel-2` | 13 | 162754 ms (~162.8 s) |
| imbalance | | 318 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated, `real-herdr-gated`, nor `live-harness-optin`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, GUI-backend, and other unproven work serial, while `live-harness-optin` stays an explicit opt-in outside every portable lane and therefore outside every serial CI shard, because its members need machine state CI does not have - real harness credentials, or a real browser session.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The hints came from run [32191955185](https://github.com/HelloWorldSungin/firstmate/actions/runs/32191955185) on 2026-08-18, where 121 of the lane's 129 scripts reported a measured duration totalling 2819209 ms of serial work.
The remaining eight are the tail of the shard that was cancelled at its timeout before finishing them, so they keep the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default until a completed run measures them.
A script with no hint gets that same default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.

Shard count is sized from that total rather than left where an earlier, smaller remainder put it.
The lane grew from about 19 minutes across 69 scripts to about 47 minutes across 129, which four shards could no longer carry inside the job timeout: on the run above, `portable-serial-2of4` was cancelled at 15 minutes having finished 24 of its 32 scripts, and the same measurements put a perfectly balanced quarter at 12.4 minutes, still on the tripwire rather than inside it.
Eight shards put a balanced shard at 6.2 minutes.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of8` | 15 | 372407 ms (~372.4 s) |
| `portable-serial-2of8` | 16 | 372408 ms (~372.4 s) |
| `portable-serial-3of8` | 15 | 372388 ms (~372.4 s) |
| `portable-serial-4of8` | 15 | 372407 ms (~372.4 s) |
| `portable-serial-5of8` | 17 | 372407 ms (~372.4 s) |
| `portable-serial-6of8` | 18 | 372402 ms (~372.4 s) |
| `portable-serial-7of8` | 17 | 372398 ms (~372.4 s) |
| `portable-serial-8of8` | 16 | 372392 ms (~372.4 s) |
| imbalance | | 20 ms |

The single longest script, `tests/fm-watch-triage.test.sh` at 210485 ms, is the floor for any shard count.

Refresh the hints by downloading the per-shard timing artifacts from a green CI run, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the measured `path`/`duration_ms` pairs, and updating the table above:

```sh
gh run download <run-id> -R HelloWorldSungin/firstmate --pattern 'fm-test-timing-portable-serial-*' -D /tmp/fm-serial
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*.json | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, real-Herdr family, and live-harness opt-in family are disjoint and together cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| portable parallel 1/2 | 10 | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-8 | 15 | Each balanced shard is about 6.2 minutes, leaving roughly 2.4x hang-tripwire margin. |
| Herdr | 75 | The real-Herdr lane keeps its dedicated timeout. |

Timeouts are hang tripwires rather than expected healthy durations.
