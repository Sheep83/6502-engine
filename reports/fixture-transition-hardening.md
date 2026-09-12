# Fixture transition hardening — MAXCAP one-shot publication

**Result: GREEN (hardening). A real race window was measured and closed; the
visual corruption was not reproduced and is not claimed.**

The hypothesis in the brief was right, and the mechanism turned out to be
specific and measurable rather than vague:

> **`buildSchedule` latches its destination from `schedNext` once, at entry, and
> then writes that buffer for thousands of cycles. The frame IRQ promotes
> `schedNext` to CURRENT whenever `schedPending` is set. So a build that *starts*
> while a publication is still pending has its destination promoted underneath
> it, and the executor renders a half-written schedule.**

Measured on the unfixed engine: **11.7% of RING-SLOW builds began in that
state** (14 of 120 sampled). The window is real, frequent, and structurally
able to promote a half-written buffer.

A fixture that rebuilds every frame survives this — the next frame overwrites
the damage, and it costs at most one bad frame. **MAXCAP does not rebuild.** It
is static and publishes exactly once, so a schedule corrupted during its
activation stays corrupted for as long as the fixture is displayed. That is
precisely the asymmetry the brief predicted, and it explains why `1F/20/21`
looked stable while `FIX 16` did not.

I did **not** reproduce the striped-garbage screenshot, and — importantly — I
also did **not** cleanly demonstrate that this race corrupts CURRENT in
practice. See §6 and §12, where an earlier apparent demonstration is retracted
because it was confounded by my own harness. What stands is: the window is
measured, the mechanism is structural and unambiguous from the source, the fix
costs six instructions, and the fixed engine is strictly safer than the one it
replaces.

---

## 1. Fixture activation path

```
key edge (SPACE / M / S / R)      polled at the TOP of mainLoop, ungated
  -> fixtureIndex changes
  -> jsr rebuild
       loadFixture      clearMotion, logical state, pointers, colours, sortReset
       republish        sortTick -> buildSchedule -> publishSchedule
  -> schedPending = 1
  -> frame IRQ at raster 250      swaps CURRENT <-> NEXT, clears pending
  -> executor consumes CURRENT
```

The key polls sit **above** the `frameCounter` gate, so `rebuild` runs in
whatever raster phase the key happens to be seen in — including partway through
a frame, and including while a previous publication is still pending. That is
the exposure.

## 2. Static MAXCAP publication behaviour

`fixtureMoves = 0`, so the per-frame branch in `mainLoop` never calls
`republish`. MAXCAP therefore performs **exactly one** `buildSchedule` and
**exactly one** `publishSchedule`, ever, at activation. Nothing downstream
repairs it. Every piece of its presentation state — `logCount`, `sortedCount`,
`logY/logX/logXHi`, `logPtr`, `logCol`, and the schedule itself — is written
once and must remain valid indefinitely.

## 3. Dynamic P5 publication behaviour

`fixtureMoves = 1`, so every frame runs `motionTick` then `republish`: a fresh
`sortTick`, `buildSchedule` and `publishSchedule`. Any one-frame damage is
overwritten on the next frame. This is why the ring fixtures are visually stable
even though they hit the racy state far more often than MAXCAP does — they hit
it constantly and heal constantly.

## 4. Transition stress matrix

`tests/test_transition.py`. Sources chosen to cover each fixture kind:

| from | kind | to |
|---|---|---|
| `0F` (15) | P2 static | `16` |
| `11` (17) | P3 moving | `16` |
| `1F` (31) | P5 ring | `16` |
| `20` (32) | P5 ring | `16` |
| `21` (33) | P5 ring | `16` |

Each route is repeated (5× full, 2× quick), and the activation phase is left to
the natural jitter of the running machine rather than forced — see §12 for why
forcing was rejected.

## 5. First-frame invariants

Checked on every transition, on the first CURRENT the executor consumes:

```
fixtureIndex == 22            logCount == 30          sortedCount == 30
statAccepted == 24            statOverflow == 6
CURRENT entries == 24         CURRENT batches == 19
CURRENT Y values are MAXCAP's           (not the previous fixture's)
CURRENT logical ids are MAXCAP's        (no mixed-fixture state)
every accepted id -> its OWN 64-byte bitmap, byte for byte vs build/engine.prg
ringActive == 0               fixtureMoves == 0       (no P5 leakage)
frameEntryLine == 250
statPageMismatch == 0         statPtrMismatch == 0    sortFault == 0
```

## 6. Was the corruption reproduced?

**No, to both the visual symptom and — on honest re-examination — to the
schedule corruption itself.**

An intermediate probe did report, on the unfixed engine:

```
ENGINE: built but CURRENT still has 0 entries      2/14
```

**I am retracting that as evidence.** That probe's activation helper did not
verify the isolated call had returned, so some of its builds were abandoned
part way by the harness. An abandoned build leaves a genuinely partial buffer,
and combined with the probe's forged `schedPending` that is sufficient on its
own to promote an empty CURRENT. The engine race is not needed to explain it,
so it does not prove the engine race.

When the same construction is run with a *verified* activation — section 2b of
the regression, 14 builds started over a genuinely pending publication — CURRENT
always held one complete schedule or the other, **with the guard and without
it**. So the natural race is narrow enough that neither 25 single-shot MAXCAP
activations nor 14 constructed ones caught it corrupting anything.

## 7. Was the activation race proven?

**The window is proven to exist and to be frequent. It is not proven to have
caused observable corruption.** Both halves matter:

- `schedPending` was already set at `buildSchedule` entry on **11.7%** of
  RING-SLOW builds (14 of 120 sampled) — the window is not theoretical.
- With the guard in place, `schedBuildDefer` (which counts exactly that entry
  condition) reaches 30–255 within a second or two of running, so the guard is
  load-bearing rather than dead code.

The window opens whenever the frame IRQ lands **between** `buildSchedule` and
`publishSchedule`: the publication then misses that frame's swap and is still
waiting when the next pass starts building.

What is *not* established is the last step — that the IRQ then actually lands
inside the following build often enough to matter. The build occupies roughly
half a frame, so the conditional probability is far from negligible, but I did
not observe the resulting corruption under controlled conditions. The fix is
justified on the window being real and the cost being six instructions, not on
a reproduced failure.

## 8. P5 state leakage

**None found.** `clearMotion` (called by `loadFixture` before any fixture kind
dispatch) zeroes `ringActive` and `fixtureMoves`, and the dispatch tables read
back correct from the assembled binary (`fixtureKind[22] = 0`,
`fixtureLen[22] = 30`). Instruction-level trace of the ring → MAXCAP switch:

```
loadFixture -> clearMotion -> sortReset -> republish -> sortTick
            -> buildSchedule -> publishSchedule
result: logCount 30, sortedCount 30, accepted 24, overflow 6, ringActive 0
```

`ringActive` and `fixtureMoves` are asserted zero on every transition in §5.

## 9. Page and pointer transition

`statPageMismatch` and `statPtrMismatch` are zero on every transition, and the
`$07F8`/`$2BF8` identity of every accepted sprite is verified against the build
artefact by `tests/sprite_identity.py` as part of the first-frame invariants.

## 10. Architectural hardening

`src/renderer.asm`, at the top of `buildSchedule` — **withdraw any pending
publication before writing `schedNext`**:

```asm
buildSchedule:
    lda schedPending
    beq !notPending+
    lda #0
    sta schedPending
    lda schedBuildDefer          // saturating diagnostic
    cmp #$ff
    beq !notPending+
    inc schedBuildDefer
!notPending:
```

Why this is the right shape:

- **It loses nothing.** The publication being withdrawn is the one sitting in
  `schedNext` — the very buffer this build is about to overwrite. It was already
  superseded. `publishSchedule` re-sets the flag once the buffer is complete.
- **It preserves the immutable NEXT→CURRENT model exactly.** CURRENT is still
  swapped only at the frame boundary, still consumed alone, and the executor is
  untouched. No new state machine, no activation delay, no arbitrary waiting.
- **It does not touch the frame interrupt**, so the executor's cost and its
  relative-branch ranges are unchanged — which matters, because the first
  attempt did touch the IRQ and broke a branch range.
- **It cannot make future border/HUD raster handoff harder**, because it adds
  nothing to raster time and makes no assumption about raster availability.

### A worse design, tried and rejected

The first attempt was a `bs_building` flag set at build entry and cleared at
build exit, with the frame IRQ refusing to swap while it was set. That is a
**lock released only on the normal exit path**: a build abandoned part way
leaves it set for ever and the frame IRQ never swaps again, freezing CURRENT on
the previous fixture permanently. The transition test caught exactly that —
`0f->16: CURRENT has 12 entries / 2 batches` — which is a *worse* failure than
the one being fixed. The form above has no such state.

**No bounded republish was added.** Production correctness must not depend on
repeatedly repairing a bad first publication, and with the race closed there is
nothing to repair.

## 11. Transition regression

`tests/test_transition.py`, wired into `make test-transition`, `make test-fast`
and `make test-full`. It detects mixed old/new fixture state, stale CURRENT,
partial NEXT publication, bad first-frame pointer identity, P5 leakage, and
page/pointer destination mismatch.

It also verifies its **own** activation honestly. The isolated-call trick is the
only way to drive `rebuild` from a harness, and `AGENTS.md` documents that the
monitor returns from `x` on a prompt echo rather than the actual stop. So
`activate()` requires the PC to have reached the sentinel *and* the build stats
to be right, and retries otherwise. Checking `statAccepted` alone is not enough:
`buildSchedule` writes those stats partway through, so a call abandoned in its
final pass reports 24/19 and never reaches `publishSchedule` — which then looks
exactly like a lost publication. Two apparent "engine faults" during this task
were that, and are recorded rather than buried.

## 12. Deliberate fault proof

The guard was removed and the full suite re-run. **The transition matrix did
not catch it**, and that is reported rather than hidden:

```
guard REMOVED, full matrix:
  ok   every transition into MAXCAP yields a complete, unmixed CURRENT -- 25 transitions
  ok   a build never leaves a PARTIAL schedule in CURRENT -- 14 constructed builds
  FAIL the dangerous build-while-pending state still occurs -- 0 builds began with
       a publication pending
```

Only the **meta-check** fails, because `schedBuildDefer` disappears with the
guard. So what the regression actually detects is *the guard's removal*, not the
corruption it prevents — the corruption is too rare to catch in 25 single-shot
activations or 14 constructed ones.

That is a weaker claim than "the regression catches the fault", and it is the
true one. The invariant battery in §5 remains valuable — it catches mixed state,
stale CURRENT, wrong bitmap identity, P5 leakage and page/pointer mismatch, any
of which would be immediate and obvious — but nobody should believe it is a trap
for this particular race.

### A forged state that was rejected

An earlier draft poked `schedPending = 1` before activation to force the racy
condition. That was wrong and the test no longer does it: pending set with **no
fresh schedule in the buffer** is a state the engine never produces, and it
causes one spurious swap that leaves CURRENT holding a stale buffer — a fault
invented by the test. The real condition occurs often enough to rely on
(§7), so the regression waits for it rather than forging it.

## 13. Memory-gap guard

The P5 forensic measured five bytes of headroom between the scroller and the
`motion` segment at `$1c00`. KickAssembler places explicit `* =` segments where
told and does **not** complain when one grows into the next — it overwrites
silently, and the failure looks like corrupted code rather than a build error.

Guards added at the end of both tight segments:

```asm
.if (* > $1c00) { .error "the scroller segment has grown into 'motion' at $1c00" }
.if (* > $1a00) { .error "the 'fixtures code' segment has grown into 'scroller' at $1a00" }
```

Proved to bite: inserting 16 bytes of deliberate growth into the scroller fails
the build with `the scroller segment has grown into 'motion' at $1c00`.

## 14. Targeted test result and runtime

```
make test-transition            ALL PASS
  25/25 transitions into MAXCAP yield a complete, unmixed CURRENT
  schedBuildDefer non-zero: the guard is load-bearing
  RING-SLOW / RING-FAST / RING-SHIFT all activate to a complete schedule
runtime: 668s full matrix, 291s --quick
```

## 15. test-fast

```
make test-fast          11m59s wall clock

  p5_model audit                        clean
  gen_p5_tables --check                 matches
  test_transition.py --quick            ALL PASS
  test_p5.py --fast                     6 FAILURES
```

The six P5 failures are the **known, pre-existing publication-skip AMBER**
documented in `reports/p5-rotating-ring-torture.md` §18 — the same six lines,
three modes × (counter saturated, non-zero skips). They are a main-thread
capacity result, unrelated to and unaffected by this change, and they were
already failing before it.

**Nothing in `test-fast` regressed.**

## 16. test-full

**Not run, deliberately, and here is the reasoning rather than a reflex.**

The production change is six instructions at the top of `buildSchedule` that
clear a flag the frame IRQ reads. It does not touch the executor, the batch
path, the sorter, the builder's output, the scroller or any fixture data. The
behaviour it changes is exactly one thing: a publication that was about to be
promoted from a buffer being overwritten is now withdrawn instead.

What would a full P0–P5 sweep add? The schedule *contents* are already compared
against the independent model on every transition here and by `test_p3`'s MAXCAP
section; the executor is unchanged; the raster-250 invariant is asserted in the
transition test. The remaining coverage is a multi-hour re-proof of behaviour
this change cannot reach.

**My recommendation is to run `make test-full` once before the next checkpoint
is declared**, not as part of this task — the brief's own instruction was not to
spend hours re-proving unrelated qualified behaviour. If you would rather I run
it now, say so and I will.

## 17. Manual retest

Windowed, normal speed (`make run`). Navigate with SPACE; **M**, **S**, **R**
jump to the first P3, P4 and P5 fixture.

```
0F -> 16        (static source)
11 -> 16        (moving source)
1F -> 16        20 -> 16        21 -> 16        (ring sources)
16 -> anything -> 16            (return path)
```

For **FIX 16** each time: all 24 accepted sprites present and showing their own
numerals, no horizontal striped garbage, no fragmentation, `ACC 18`, `OVF 06`,
`LOG 1E`, `SRT 1E`, and `FEL FA` steady. Repeat the route several times — the
race this fixes was intermittent, so a single clean arrival proves less than
half a dozen.

For **1F / 20 / 21**: unchanged visual stability, scrolling no worse.

**I am not declaring manual GREEN.** That is yours.

## 18. VICE and disk hygiene

`pgrep -fl x64sc` before the work and after: none outstanding. Every launch kept
its exact PID and was reaped; one long run was stopped deliberately and its
owned VICE killed by exact PID and verified gone. No broad `pkill`, no
`open -a`, `-console` throughout, no focus taken. Transient captures stayed in
the session scratchpad.

```
du -sh build/    68K
du -sh .         2.2M
```
