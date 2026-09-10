# AGENTS.md — 6502-engine

A PAL C64 rendering/multiplexing **qualification laboratory**. Not a game.
Read this before changing anything.

## Target and toolchain
- Commodore 64, **PAL**, 19,656 cycles/frame. Never optimise for NTSC.
- **Legal NMOS 6502/6510 only.** No illegal opcodes.
- KickAssembler 5.25 (`/Users/brianmorrice/dev/tools/kickassembler/KickAss.jar`).
- VICE 3.10, `x64sc` (`/opt/homebrew/bin/x64sc`).

## The two rules that matter most

**1. Manual visual output is authoritative.**
A checkpoint is not GREEN if counters, RAM comparisons and timing all pass but
the display visibly glitches. Automated tests are *evidence*, never a veto over
what a human can see. If a human sees corruption and the harness does not, the
**harness** is wrong. Long, normal-speed, **non-warp** observation is part of
qualification.

**2. One renderer subsystem owns gameplay sprite VIC state.**
`src/renderer.asm` owns `$D000-$D010`, `$D015`, `$D01C`, `$D027-$D02E` and the
sprite pointer table. Frame-start setup and the raster executor may both write
them because both live inside that subsystem. Nothing else may. The previous
project accumulated 13 independent writers of `$D015` and became unreasonable;
do not repeat that.

## Immutable frame schedule
Once a schedule is CURRENT the executor must render the whole frame from it
alone. The IRQ must not consult object state, allocation state, ownership flags
or a sorter. The test: *if the main thread stopped dead immediately after
publication, would the frame still render correctly?* It must.

## Checkpoint-first development
Work proceeds along the ladder in `docs/qualification-ladder.md`. Each
checkpoint stays independently runnable — P1 does not replace P0. Keep the small
fixtures so later regressions can be localised. Any smallest failing fixture is
kept permanently.

## Timing must be measured, not assumed
Document exact timing implications in the source next to the constant they
justify. `REUSE_LEAD` began as a guess of 3 lines; measurement showed the
executor costs up to 666 cycles and the test rejected the guess. Numbers like
this belong to measurement, not to intuition.

## Avoid abstraction
Prefer a small readable module with documented limits over a general one with
fragile ownership. If a change starts to look like a miniature re-creation of
the old engine's BUILD/LIVE/adaptive-reuse machinery, stop and simplify.

## VICE process ownership (hard invariant)
Before a suite: `pgrep -fl x64sc` and account for anything running.
Every launch must retain its **exact PID** and terminate + reap it on success,
failure, timeout and exception (`try/finally` or `trap`). Verify at the end that
no test-owned VICE remains. Do **not** use broad `pkill` when the PID is known,
and never kill a user's manual VICE session. Never steal keyboard focus; launch
directly, never `open -a`.

Two harness traps already paid for, both in `tools/capture_p0.py`:
- any monitor command **halts** the emulator, so a harness cannot observe a
  freely-running non-warp machine — advance emulated time by stepping;
- never hijack the CPU (`r pc=...`) while stopped **inside the IRQ handler**:
  the I flag stays set, interrupts never resume, and the failure looks like a
  renderer bug.

## Build/test hygiene
`build/` holds only the current binary and symbols. No per-run directories, ever.
All screenshots, traces and captures go to `/tmp` and are deleted after use.
Report disk usage after large runs.

## Source control
**Do not commit or push unless explicitly asked.** Initialising a repo and
configuring a remote is fine; committing is not.
