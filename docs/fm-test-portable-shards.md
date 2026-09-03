# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-08-20 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 45356 | `tests/fm-backend-herdr.test.sh` |
| 35415 | `tests/fm-x-mode.test.sh` |
| 35095 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 27529 | `tests/fm-arm-pretool-check.test.sh` |
| 20922 | `tests/fm-test-run.test.sh` |
| 17558 | `tests/fm-crew-state.test.sh` |
| 16582 | `tests/fm-cd-pretool-check.test.sh` |
| 9766 | `tests/fm-lint.test.sh` |
| 9562 | `tests/fm-herdr-lab.test.sh` |
| 6768 | `tests/fm-grok-harness.test.sh` |
| 6290 | `tests/fm-pr-merge.test.sh` |
| 5569 | `tests/fm-composer-ghost.test.sh` |
| 4563 | `tests/fm-send-popup-settle.test.sh` |
| 4021 | `tests/fm-tmux-submit-busy.test.sh` |
| 3544 | `tests/fm-composer-lib.test.sh` |
| 3025 | `tests/fm-send-strict.test.sh` |
| 2753 | `tests/fm-send-settle.test.sh` |
| 2166 | `tests/fm-review-diff.test.sh` |
| 1315 | `tests/fm-brief.test.sh` |
| 975 | `tests/fm-spawn-batch.test.sh` |
| 598 | `tests/fm-pi-primary-types.test.sh` |
| 513 | `tests/fm-ensure-agents-md.test.sh` |
| 331 | `tests/fm-supervision-instructions.test.sh` |
| 99 | `tests/fm-transition-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 134295 ms (~134.3 s) |
| `portable-parallel-2` | 13 | 126020 ms (~126.0 s) |
| imbalance | | 8275 ms |

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
The hints came from run [32191955185](https://github.com/HelloWorldSungin/firstmate/actions/runs/32191955185) on 2026-08-18, which measured the lane as it stood then.
The inherited `tests/fm-tool-update-check.test.sh` hint comes from upstream green run [32461816719](https://github.com/kunchenguid/firstmate/actions/runs/32461816719), the first run that measured it.
Recomputed against the current lane on 2026-09-03: 124 of its 154 scripts carry a measured hint totalling 2871221 ms.
The other 30 are unmeasured - tests added since those runs, plus the tail of the shard that was cancelled at its timeout before reaching them - so they keep the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default until a completed run measures them, which puts the lane's estimated total at 3471221 ms.
A script with no hint gets that same default, and a hint naming a script the lane no longer contains is simply unused.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for a shard to time out.

Shard count is sized from that total rather than left where an earlier, smaller remainder put it.
The lane grew from about 19 minutes across 69 scripts to about 58 minutes across 154, which four shards could no longer carry inside the job timeout: on the run above, `portable-serial-2of4` was cancelled at 15 minutes having finished 24 of its 32 scripts, and the current hints put a perfectly balanced quarter at 14.5 minutes, still on the tripwire rather than inside it.
Eight shards put a balanced shard at about 7.2 minutes.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of8` | 17 | 433890 ms (~433.9 s) |
| `portable-serial-2of8` | 19 | 433922 ms (~433.9 s) |
| `portable-serial-3of8` | 19 | 433897 ms (~433.9 s) |
| `portable-serial-4of8` | 19 | 433900 ms (~433.9 s) |
| `portable-serial-5of8` | 20 | 433900 ms (~433.9 s) |
| `portable-serial-6of8` | 20 | 433895 ms (~433.9 s) |
| `portable-serial-7of8` | 20 | 433908 ms (~433.9 s) |
| `portable-serial-8of8` | 20 | 433909 ms (~433.9 s) |
| imbalance | | 32 ms |

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

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-8 | job `timeout-minutes: 15` | Each balanced shard is about 7.2 minutes, leaving roughly 2.1x hang-tripwire margin. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finish around 7 minutes, so the step bound is the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.

Inside each lane, `bin/fm-test-run.sh` applies its own default per-script bound, so a hung script usually turns red with per-script attribution before the job cap cancels the lane; its `--help` owns that bound's value and opt-out, and the rationale beside `DEFAULT_PER_SCRIPT_TIMEOUT_SECS` owns the per-lane margin arithmetic.
Neither portable lane has room to spare, because a hung script spends the bound instead of its own healthy slot.
On a serial shard the result lands just inside the 15-minute cap on script time alone, before this lane's checkout and bootstrap: expect per-script `exit=124` in the usual case, and the job timeout first when the hung slot sits late in the shard and setup overhead runs high.
The portable parallel cap is tighter still, and a hang there reaches the job timeout first more often than occasionally.
