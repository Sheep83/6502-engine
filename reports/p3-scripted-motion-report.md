# P3 — scripted motion qualification report

**Checkpoint: P3 — scripted moving logical sprites feeding the qualified P0–P2
builder and executor.**

Status: **automated evidence GREEN. Manual visual acceptance NOT YET PERFORMED**
— see §17. Under this repository's own rules a checkpoint is not GREEN until a
human has watched a non-warp run, and that has not happened for P3.

---

## 0. Summary

P3 makes the moving case true without changing the renderer's shape. Logical
X/Y are recomputed every frame, a **complete** NEXT schedule is built from those
moved values under the same acceptance rules, publication is still one byte, and
the executor still consumes an immutable CURRENT and is never told that anything
moved.

| | |
|---|---|
| executor critical path vs P2 | **identical at every batch size, delta +0** |
| worst moving six-entry batch | **646 cycles**, margin **+110** — P2's static worst |
| `$D010` 0→1 and 1→0 on every reused slot | **proved**, `$a8` → `$54`, exact complements |
| moving crossings of 255↔256 | **proved**, both directions, 3 distinct `$D010` patterns |
| gap-33 admission, no hysteresis | **proved**, `R R A A A R` period 6 |
| `MAX_SCHED` overflow | **reported**: 30 offered, 24 accepted, `OVF = 6` |
| renderer failures | **0** |
| publication skips (final) | **0** |

**One real defect was found and fixed, and it was not in the renderer.** The
executor was untouched; what P3 cost was *main-thread* time. Drawing all five
diagnostic HUD rows every frame pushed per-frame preparation to **74.6%** of a
PAL frame, passes began straddling the frame boundary, and `publishSkip` became
non-zero — 70 skips in 20,000 frames, which a human sees as an occasional
one-frame scroll stutter. Redrawing one HUD row per frame dropped preparation to
**67.8%** and skips to **zero**.

**The scarce resource is now the main thread, not the raster executor.**

---

## 1. Files changed

| file | change |
|---|---|
| `src/motion.asm` | **new** — logical sprite state, motion state, `motionTick`, `clearMotion` |
| `src/p3_fixtures.asm` | **new, generated** — the eight P3 fixture record tables |
| `tools/gen_p3_fixtures.py` | **new** — emits the above from `tests/p3_model.py`; `--check` fails on drift |
| `tests/p3_model.py` | **new** — independent motion model and the P3 fixture declarations |
| `tests/test_p3.py` | **new** — the P3 suite |
| `src/renderer.asm` | `MAX_LOGICAL` 24→32; `schedXHi`; `statOverflow` / `statBatchOverflow`; capacity check before the reuse rule; the `$D010` pass now **sets** as well as clears; two branches made absolute for range |
| `src/fixtures.asm` | `FIXTURE_COUNT` 16→24; `fixtureKind` dispatch; `loadMotionFixture`; logical arrays moved out; `fxColour` to 32; assemble-time guards |
| `src/main.asm` | `republish` split from `rebuild`; motion in the main loop; `HUD_ROW_P3` (row 21); HUD redraws one row per frame; `M` key; two-digit fixture id |
| `src/scroll.asm` | row 21 treated as a HUD row |
| `tests/p2_model.py` | `build()` takes 9-bit X, computes per-batch `$D010`, models the capacity fault |
| `tests/test_p1.py` | `HUD_ROWS` now `(1, 2, 21, 22, 23)` |
| `Makefile` | `test-p3`, `p3-fixtures`; `test` runs P0–P3 |
| `README.md`, `docs/qualification-ladder.md`, `docs/manual-acceptance.md` | updated |
| `docs/p3-scripted-motion.md` | **new** |

Memory map after P3 (nothing moved into VIC bank 0's way):

```
$0810-$0b99 main            $1c00-$1d0a motion
$1000-$1278 schedule builder $2000-$23ff diagnostic sprites
$1500-$173e raster executor  $c000-$c248 schedule buffers
$1800-$19fd fixtures         $c300-$c3a2 logical sprite state
$1a00-$1bf6 scroller         $c400-$c505 motion state
                             $c600-$c94b p3 fixture data
```

---

## 2. Architecture confirmation

The required order is what the code does:

```
motionTick        moves logical X/Y              main thread
buildSchedule     builds NEXT from those MOVED values
publishSchedule   one byte
frame IRQ         adopts CURRENT
executor          consumes CURRENT only
VIC
```

Asserted, not asserted-by-assertion:

- **the executor references no motion or logical state** — checked at source
  level over the whole handler body for `motionTick`, `logX`, `logY`, `logXHi`,
  `mvXVel`, `mvYVel`, `motionFrame`, `fixtureMoves`: zero references;
- **`motionTick` is called from exactly one place**, in the main loop;
- **nothing outside the builder writes a schedule array**;
- **CURRENT is immutable** — with the main thread parked on a jump-to-self,
  5,028 frames rendered while CURRENT's Y values, X values *and prepared
  `$D010`* were byte-identical before and after, and motion stopped dead
  (`motionFrame` 19795 → 19795) with no coherence fault;
- **moving sprites go through the same `i-6` gap rule** — every accepted entry's
  gap is recomputed from the engine's own schedule and checked against
  `MIN_REUSE_GAP` on every frame compared.

Nothing prebuilds a schedule and mutates X/Y underneath it; nothing patches
CURRENT after publication.

### The one architectural mistake made, and caught

The first version of the main loop called **`rebuild`** every frame. `rebuild`
begins with `loadFixture`, so every frame reset every position and `motionFrame`
immediately after `motionTick` had advanced them. Motion never accumulated: the
sprites sat still, `motionFrame` read 0 forever, and the wasted reload cost
enough main-thread time to start skipping scroll publications. Fixed by
splitting **`republish`** (build + publish, for the per-frame path) from
**`rebuild`** (load + build + publish, for fixture selection), so the difference
between "select this fixture" and "prepare the next frame" cannot be blurred
again.

---

## 3. Movement representation

One primitive, per axis, and no per-sprite "kind" to dispatch on:

```
pos += vel
if pos >= max:  pos = max;  vel = -vel
if pos <= min:  pos = min;  vel = -vel
```

`vel == 0` means the axis is untouched, so static and moving share one path. The
result is an exact integer triangle wave, which is the point: the harness states
the expected position for frame N in closed form and compares it, rather than
comparing the engine against itself.

Reversing on `>=` rather than `>` is deliberate. With a strict comparison the
bound is hit, then overshot and clamped, so each endpoint appears twice
(`32 33 34 34 33 32 31 31`); reversing on `>=` gives a clean triangle with each
endpoint once (`32 33 34 33 32 31`) — the one a human can check by eye.

X is 16-bit (`logX` + `logXHi`, 0…511), Y is 8-bit. There is **no overflow
handling**, and that is a precondition enforced at **assembly time**: the `p3s`
macro refuses to build a fixture whose bound sits within one velocity step of 0
or of the axis maximum. Carrying an unreachable runtime guard instead would be
exactly the "unreachable-in-theory path" this repository's own reuse inventory
blames for hiding real failures.

Per-sprite state: `mvXVel`, `mvXMin{Lo,Hi}`, `mvXMax{Lo,Hi}`, `mvYVel`,
`mvYMin`, `mvYMax` — eight arrays of `MAX_LOGICAL`, outside VIC bank 0 with the
schedule buffers. `clearMotion` runs on every fixture load, so a fixture can
never inherit the previous fixture's trajectory — not theoretical when fixture
selection is one SPACE press away on a live machine. `motionFrame` restarts at
zero with every load, so "fixture 20, motion frame 7" names exactly one set of
positions.

---

## 4. Per-fixture movement rules

| # | name | movement | proves |
|---|---|---|---|
| 16 | `MOVE6` | 6 sprites: one X-only, one Y-only, one diagonal, one static, two X-only | motion and publication in isolation — no slot is ever reused |
| 17 | `MSBFLIP6` | none (static geometry) | `$D010` 0→1 and 1→0 on all six reused slots |
| 18 | `X255` | two sprites ping-pong X across 255/256, `vel ±2`, bounds 230…290 | moving MSB crossings on reused slots |
| 19 | `YMOVE` | two **rigid** groups translate in Y, `vel +1` | legal reuse while Y moves; the batch raster moves with it |
| 20 | `GAP33` | one candidate ping-pongs Y over gaps 31…34, `vel ±1` | admission across the conservative threshold |
| 21 | `SHAPE` | as `GAP33`, plus a six-sprite merged group below it | one admission reshaping the whole schedule |
| 22 | `MAXCAP` | none; 30 sprites at uniform pitch 6 | `MAX_SCHED` overflow |
| 23 | `MOTION12` | 12 sprites, all moving in X and Y, two crossing 255 | the integrated case |

**Y order is never allowed to change.** Groups that move in Y translate
*rigidly* — one velocity, one relative phase — so their relative order is fixed
by construction. Independent phases would let two sprites swap Y order, which P3
has no sorter for. `p3_model.audit()` asserts ascending Y on every frame of
every fixture, and the suite re-asserts it against the running machine on every
frame it compares.

X moves freely, including across 255/256, because X cannot affect Y ordering.

---

## 5. X-MSB static reuse — `MSBFLIP6`

Six leaders and six reusers on the same six physical slots, every slot's MSB
inverted on reuse, merged into one six-entry mid-screen batch.

```
leaders  slot/X/MSB  (2,  40, 0) (3, 264, 1) (4, 100, 0) (5, 300, 1) (6, 160, 0) (7, 336, 1)
reusers  slot/X/MSB  (2, 264, 1) (3,  40, 0) (4, 300, 1) (5, 100, 0) (6, 336, 1) (7, 160, 0)
batch $D010          $a8  ->  $54
```

| check | result |
|---|---|
| schedule and complete `$D010` match the independent model | **pass** |
| every one of the six slots changes its MSB on reuse | **pass** |
| both directions covered, 0→1 and 1→0 | **pass** |
| the reusers form ONE six-entry merged batch | **pass** |
| the two `$D010` values are exact complements on the mux bits | **pass**, `$a8 ^ $54 = $fc` |

`$a8` is slots 3, 5, 7; `$54` is slots 2, 4, 6. Every mux bit flips in one
batch, which is the strongest form of the test and makes a stale bit impossible
to miss on screen — it would put a sprite 256 pixels from where it belongs.

**Observed on the machine, not inferred from source.** Stopping after the last
batch of a frame, the live `$D010` register read **`$54`** — exactly the value
the builder had prepared for that batch, and exactly what the model says. Every
mux slot's X low byte *and* MSB matched the CURRENT schedule's last writer for
that slot.

---

## 6. Moving 255↔256 — `X255`

70 consecutive frames compared against the model, every frame.

```
crossings over 70 frames:  2 upward, 2 downward
MSB values seen per slot:  {2: [0,1], 3: [0,1], 4: [0], 5: [0,1], 6: [0], 7: [1]}
distinct batch-$D010 patterns:  ($88,$a8)  ($8c,$a0)  ($8c,$a8)
```

Slot 2 carries a *crossing leader* and a *fixed-MSB-0 reuser*; slot 3 carries a
*fixed-MSB-1 leader* and a *crossing reuser* — so both orders of
(crossing, fixed) occur on a reused slot. Three slots carry both MSB values over
the run.

| check | result |
|---|---|
| sprites cross 255→256 and 256→255 repeatedly | **pass** |
| a crossing happens on a slot reused with the other MSB | **pass**, slots 2, 3, 5 |
| the complete `$D010` really changes as sprites cross | **pass**, 3 distinct patterns |
| logical X/Y match the model every frame | **pass**, 70/70 |
| NEXT schedule built from the moved values | **pass**, 70/70 |

---

## 7. Moving-Y reuse — `YMOVE`

60 consecutive frames compared.

```
reuse gaps seen:                36..49   (MIN_REUSE_GAP 33)
mid-screen batch rasters:       93 94 95 96 97 98 99
accepted set:                   12, on every frame
```

The geometry genuinely moves — the gap varies by 13 rasters and the mid-screen
batch fires on seven different lines — while every reuse stays legal (minimum
gap 36) and the accepted set stays stable. That is the intended separation:
`YMOVE` moves the schedule without moving the admission decision, so any fault
is attributable to motion rather than to admission.

---

## 8. Gap-33 threshold crossing — `GAP33`

The candidate's same-slot predecessor is accepted entry 0 at a fixed Y, so the
reuse gap *is* the candidate's Y offset. It walks one raster per frame:

| frame | gap | admission | accepted | batches |
|---:|---:|---|---:|---:|
| 0 | 31 | rejected (conservative) | 6 | 1 |
| 1 | 32 | rejected (conservative) | 6 | 1 |
| 2 | **33** | **ADMITTED** | 7 | 2 |
| 3 | 34 | ADMITTED | 7 | 2 |
| 4 | 33 | ADMITTED | 7 | 2 |
| 5 | 32 | rejected (conservative) | 6 | 1 |
| 6 | 31 | rejected (conservative) | 6 | 1 |

…repeating with period 6. Verified over 30 consecutive frames against the model.

| check | result |
|---|---|
| the candidate crosses the threshold in both directions | **pass**, gaps 31–34 |
| admission is exactly the gap rule, with **no hysteresis** | **pass** |
| a sprite rejected at gap 32 is admitted again at gap 33 | **pass** |
| rejection is CONSERVATIVE, never physically-unsafe, at this gap | **pass** |

**This is the correct result, and P3 deliberately does not soften it.** The
accepted count changes on alternate frames and the sprite blinks. No hysteresis
was added, because the brief asks for evidence before policy and there is now
evidence to argue from. The three outcomes that must never be conflated are
distinguished on screen by `ACC` on row 1 against what is actually visible — see
§17.

---

## 9. Schedule-shape mutation — `SHAPE`

The candidate sits between the leaders and a six-sprite merged group. Admitting
it shifts every later entry's same-slot predecessor by one, so the group's last
member is suddenly measured against the candidate instead of against a leader —
and is rejected. **Admitting one sprite removes another.**

| gap | candidate | accepted | batches | merged width | batch rasters | `$D010` | rejected |
|---:|---|---:|---:|---:|---|---|---|
| 31 | out | 12 | 2 | 6 | 250, 108 | `$00 $a8` | sprite 6 |
| 32 | out | 12 | 2 | 6 | 250, 108 | `$00 $a8` | sprite 6 |
| 33 | **in** | 12 | **3** | **5** | 250, **81**, 108 | `$00 $00 $50` | **sprite 12** |
| 34 | **in** | 12 | **3** | **5** | 250, **82**, 108 | `$00 $00 $50` | **sprite 12** |

Every one of the required mutation axes changes frame to frame: batch **count**
(2↔3), merged batch **width** (6↔5), batch **rasters** (81/82 appearing), the
complete **`$D010`** (`$a8`↔`$50`, because the group members move onto different
physical slots), and **which sprite is rejected** (6↔12). The accepted count
varies on `GAP33` (6↔7).

Alternating repeatedly between four very different fixtures — `SHAPE`, `GAP33`,
`MSBFLIP6`, `MOVE6` — left **nothing stale**: every field of every schedule
matched the model after each switch, three times over.

A note on what "no stale data" means here: the executor is bounded by
`schedBatches` and `batchCount`, so the guarantee that matters is that those
bounds are correct and that coverage is exact (`sum(count) == accepted`), not
that unused array tails are zeroed. Both are asserted.

---

## 10. `MAX_SCHED` overflow

P2 flagged that the builder stopped adding at the cap rather than reporting it.
Fixed, and made testable: **`MAX_LOGICAL` is now 32 while `MAX_SCHED` stays 24**,
so the cap can actually be exceeded. `MAX_SCHED` was **not** raised to avoid the
fault path.

Capacity is checked **before** the reuse rule. A sprite there was no room for is
never also described as "rejected for spacing" — that would be a lie the
independent model would have to reproduce. The scan continues, so `statOverflow`
reports *how many* were dropped.

| case | fixture | result |
|---|---|---|
| accepted < `MAX_SCHED` | every other fixture | no fault |
| accepted == `MAX_SCHED` | `T6X3` (14) | accepted 24, **overflow 0** — the boundary does not false-positive |
| attempted > `MAX_SCHED` | `MAXCAP` (22) | offered 30, accepted 24, **overflow 6** |

| check | result |
|---|---|
| accepts exactly `MAX_SCHED` and no more | **pass** |
| the sprites that did not fit are COUNTED, not truncated silently | **pass**, 6 |
| the schedule still matches the model exactly | **pass** |
| nothing was written past the last schedule slot (memory safety) | **pass** |
| `statBatchOverflow` zero | **pass** |
| the counter clears on the next clean build | **pass** |

`statBatchOverflow` is unreachable while `MAX_SCHED` is 24 (batch 0 holds six,
so at most 19 batches can exist) but is counted rather than assumed — the same
silent truncation on the entry path is what P2 had to flag.

---

## 11. Independent model

`tests/p2_model.py` derives the expected schedule from the documented rules —
acceptance, rejection **reason**, slot, same-slot predecessor, reuse gap, batch
raster, batch membership, complete per-batch `$D010`, and the capacity fault —
with no knowledge of what the 6502 produced. `tests/p3_model.py` adds the motion
model and declares the trajectories.

Compared per frame, per fixture, against the running machine: logical X, logical
Y, X-MSB, accepted/rejected, rejection reason, hardware slot, same-slot
predecessor, reuse gap, batch raster, batch membership, complete batch `$D010`,
and complete coverage.

**On the one place the model is not independent, stated plainly.** The fixture
*inputs* — initial positions and trajectories — have a single source of truth in
`p3_model.py`, and `src/p3_fixtures.asm` is **generated** from it by
`tools/gen_p3_fixtures.py`. That is a deliberate trade: ~100 eleven-byte records
transcribed by hand is the kind of task that silently produces a fixture nobody
designed, and the failure would look like a renderer bug. What it removes is
transcription error in the inputs, **not** the independence of the expected
outputs. The inputs are additionally checked on their own terms —
`p3_model.audit()` asserts, for every frame of every fixture, that Y order still
ascends, that no entry was admitted below `MIN_REUSE_GAP`, and that every
trajectory stays a full velocity step clear of its limits — and `make test-p3`
fails if the generated file has drifted from its source.

Frame counts are part of the result: a comparison loop that breaks on the first
mismatch can otherwise report "no problems" having checked one frame. Every
walk asserts it compared *all* the frames it intended to (40, 70, 60, 30, 30).

---

## 12. Executor timing vs P2 baselines

Same phase (P2's worst, 7), same static fixtures, same geometry as the P2 report.

| batch entries | P2 baseline | P3 measured | delta | margin |
|---:|---:|---:|---:|---:|
| 1 | 212 | **212** | **+0** | +544 |
| 2 | 291 | **291** | **+0** | +465 |
| 3 | 366 | **366** | **+0** | +390 |
| 4 | 447 | **447** | **+0** | +309 |
| 5 | 520 | **520** | **+0** | +236 |
| 6 | 646 | **646** | **+0** | +110 |

**No P3 code entered the executor critical path.** The critical path is
`irqHandler → exWritesDone`, P2's probe, retained.

Moving fixtures, natural scrolling:

| fixture | samples | worst critical | deadline | margin | max entries |
|---|---:|---:|---:|---:|---:|
| `MSBFLIP6` | 648 | 646 | 756 | +110 | 6 |
| `X255` | 648 | 646 | 756 | +110 | 6 |
| `YMOVE` | 2699 | 646 | 756 | +110 | 6 |
| `MOTION12` | 648 | 640 | 756 | +116 | 6 |

A **moving** six-entry batch costs no more than P2's **static** one (646 either
way), and every moving fixture clears both the `REUSE_LEAD` deadline (756) and
the stricter sprite-fetch deadline (693). The `+110`-cycle margin P2 measured is
intact and was not spent.

This is the expected result and the reason the architecture is shaped this way:
the executor consumes a prepared schedule, so it cannot care whether the numbers
in it came from a table or from a trajectory.

---

## 13. Main-thread preparation timing

**Methodology and its limits.** Main-thread cost is measured as a **raster
span**: trace the entry of `motionTick` and the entry of `scrollPublish` and
convert the raster delta to cycles. It measures *elapsed* time, so it
**includes** the raster IRQs that interrupt it — which is the right number for
"does this finish before the next frame boundary", and an over-estimate of the
CPU work itself. It excludes `hudTick`, which runs before `motionTick` in the
same pass; the whole-pass figure is therefore somewhat larger than the numbers
below, and the publication-skip counter is the ground truth for whether the pass
actually fits.

**Before the HUD fix:**

| fixture | samples | worst prep | of 19,656 | publication skips |
|---|---:|---:|---:|---:|
| `YMOVE` | 4072 | 12,236 | 62.3% | 0 |
| `SHAPE` | 4136 | 12,029 | 61.2% | 0 |
| `MOTION12` | 4102 | **14,666** | **74.6%** | **38** |

Over a 20,000-frame `MOTION12` run, `publishSkip` reached **70**.

**After the HUD fix** (redraw one diagnostic row per frame instead of five):

| fixture | samples | worst prep | of 19,656 | publication skips |
|---|---:|---:|---:|---:|
| `YMOVE` | 4047 | 11,938 | 60.7% | **0** |
| `SHAPE` | 4041 | 11,647 | 59.3% | **0** |
| `MOTION12` | 4012 | **13,318** | **67.8%** | **0** |

`publishSkip` is now **zero** on every fixture, including over the 20,000-frame
integrated run.

### Why this was a real defect

`publishFrame` refuses to overwrite a frame record the frame IRQ has not adopted
yet, and counts the refusal. A skip means the scroller's `$d011` stays at the
previous value for one frame while `scrollFine` has already advanced — the
picture holds still for a frame and then jumps two pixels. A one-frame scroll
stutter, rare (70 in 20,000 frames) and entirely avoidable.

The cause was not motion. It was that P3 added a fifth diagnostic HUD row and
the HUD redrew **all** of them every frame, for no reason: the HUD is a
diagnostic surface, not gameplay. Every row still updates ten times a second —
faster than a human reads — at a fifth of the cost.

**The conclusion that matters for P4: the main-thread budget is now the scarce
resource, not the raster executor.** `MOTION12` uses roughly two-thirds of a
frame with 12 sprites and no gameplay in it at all.

---

## 14. Page / pointer / fine-phase coverage

`MOTION12` over the scrolling playfield, 19,971 frames:

```
frames 16205   motion frames 16205   coarse 2025   flips 2026
page A 8104    page B 8101    (A->B 1013, B->A 1013)
fine phase counts 0..7   [2025, 2025, 2025, 2026, 2026, 2026, 2026, 2025]
```

Motion advanced **exactly once per displayed frame** (16,205 = 16,205), all
eight fine-scroll phases were exercised while moving, both screen matrices were
displayed, and every coarse step flipped the page.

---

## 15. Publication / late / back-page counters

Over the integrated moving run:

| counter | value |
|---|---:|
| `$d018` / software-page mismatch | **0** |
| pointer-destination mismatch | **0** |
| late recoveries (`statLate`) | **0** |
| longest late run | **0** |
| back-page-late (`scrollLate`) | **0** |
| **publication skips (`publishSkip`)** | **0** |
| schedule overflow on a legal fixture | **0** |
| flip raster min / max | **250 / 250** |

---

## 16. Complete P0/P1/P2/P3 regression

All P0, P1 and P2 tests remain mandatory and were re-run against the final P3
binary, in one sequential run.

| suite | checks passed | failures | result |
|---|---:|---:|---|
| `test_p0.py` | 85 | 0 | **ALL PASS** |
| `test_p1.py` | 59 | 0 | **ALL PASS** |
| `test_p2.py` | 117 | 0 | **ALL PASS** |
| `test_p3.py` | 87 | 0 | **ALL PASS** |

**P0** — builder vs independent model on all five fixtures, six-slot round
robin, first reuse at accepted index 6, memory layout, executor timing:

```
handler cost: min 279  median 329  max 896 cycles
mid-screen batches: max 353 cycles over 17,968 samples
```

**P1** — 19,431-frame stress run, fixture 2:

```
renderer batches         174,871
coarse steps             2,429      page flips 2,429 (A->B 1,214, B->A 1,215)
page A / page B frames   9,715 / 9,716
fine-phase counts 0..7   [2429, 2429, 2429, 2428, 2428, 2429, 2429, 2429]
page mismatches          0
pointer mismatches       0
deadline misses (late)   0   longest run 0
back page late at flip   0
publication skipped      0
```

**P2** — worst six-entry merged batch still **646 cycles, margin +110**, worst
phase still 7, marginal cost still 86.8 cycles per extra entry. The badline
step-function and the eight-phase table are unchanged.

**P3** — 87 checks; integrated `MOTION12` run of 16,205 frames with motion
advancing exactly once per displayed frame and every coherence counter at zero.

Nothing regressed. P0/P1/P2 numbers are within run-to-run sampling variation of
the P2 report's, and the executor's measured cost is byte-identical.

---

## 17. Manual acceptance procedure

**Not yet performed. This is what remains before P3 can be called GREEN.**

```sh
make run
```

Normal speed, no monitor, no warp, real window. Press **M** to jump straight to
the first P3 fixture (fixture 16), then SPACE to advance. The bottom bar states
this: `FIXTURE nn  SPACE=NEXT  M=P3  KEY`. Fixture numbers are shown in **hex**,
as `FIX nn` always has been.

Row 21 is the P3 diagnostic: `MOV n  MFRM nnnn  OVF nn  BOV nn` — moving flag,
motion frame, schedule overflow, batch overflow. If `MFRM` freezes while the
playfield keeps scrolling, the main thread has stopped preparing frames.

### `MSBFLIP6` (17) — leave running several minutes

Every physical slot is reused by a sprite on the **opposite side of X=255** from
the one above it, so a stale `$D010` bit puts a sprite 256 pixels from where it
belongs. Watch for: a sprite suddenly jumping ~256 pixels; a sprite on the wrong
side of the screen; a sprite disappearing as its slot is reused; a wrong numeral
or colour; the previous logical owner still visible.

### `X255` (18) — watch the crossings

Two sprites slide repeatedly across the 255/256 boundary in both directions. The
movement must be **visually continuous**. A ~256-pixel jump at the crossing is a
stale-MSB failure.

### `GAP33` (20) — expected blinking, and how to tell it apart

The seventh sprite is **meant** to appear and disappear: its reuse gap walks
31→34→31 one raster per frame and admission has no hysteresis. Read `ACC` on
row 1 while watching:

| `ACC` | sprites visible | verdict |
|---|---|---|
| 07 | seven | correct |
| 06 | six | correct |
| 07 | six | **renderer failure** |
| 06 | seven | **stale sprite — failure** |

Any mismatch between the count and the display is a failure. The blinking itself
is not.

### `MOTION12` (23) — the endurance case

Several minutes across many page flips and coarse steps. Twelve sprites moving
in X and Y every frame, six slots reused every frame, some crossing X=255.
Fail on: unexplained flicker, duplicate sprite, stale sprite, wrong identity,
tearing, vertical snap, mixed A/B page letters, or corruption correlated with a
page flip.

### Additional P3 fail conditions

- `MFRM` not advancing while the playfield scrolls;
- `OVF` non-zero on any fixture except `MAXCAP` (where it must read `06`);
- `BOV` non-zero on any fixture at all;
- horizontal movement that jumps rather than slides;
- the scroll stuttering by one frame — a publication skip, which must never
  happen and now measures zero.

Manual normal-speed observation remains authoritative. Automated results do not
override it, and this suite cannot see flicker.

---

## 18. VICE process hygiene

`pgrep -fl x64sc` before the suites: **none running**.

Every launch is owned by PID, retained, terminated and reaped in `try/finally`,
and verified gone; other `x64sc` processes are reported and left alone; no broad
`pkill`; no `open -a`. All automated launches keep **`-console`**, so no window
is created and no keyboard focus is taken. `make run` remains windowed for human
acceptance.

Trace logs: one unique path per attempt, **never** unlinked while its VICE still
owns it, swept only after the process is reaped. P3 added its own
`sweep_logs()` — importing P2's swept P2's scratch directory and left every P3
trace file behind, which the end-of-suite "scratch is empty" assertion caught.

---

## 19. Build / test hygiene and disk usage

Fixed build outputs; no per-run directories. Scratch under `/tmp/6502-engine-p3`,
asserted empty before the suite exits.

```
build/                68K   (engine.prg, main.sym, main.vs)
repo excluding .git  680K
```

The generated fixture file is **not** rebuilt by `make build` — a build must
never silently rewrite source. `make p3-fixtures` regenerates it deliberately,
and `make test-p3` fails if it has drifted.

---

## 20. Renderer failures

**None.** No renderer failure occurred at any point in P3, so there is no
smallest deterministic reproducer to preserve.

Three defects were found and fixed, and it is worth being precise about what
they were:

1. **A main-loop architecture error (mine, in P3 code):** the per-frame path
   called `rebuild`, which reloaded the fixture and reset motion every frame.
   Fixed by splitting `republish` from `rebuild`. §2.
2. **A real main-thread budget defect (also P3's own doing):** five HUD rows
   redrawn every frame caused non-zero `publishSkip`. Fixed by round-robin HUD
   redraw. §13.
3. **Two harness faults**, fixed before any conclusion was drawn from them: a
   frame-stepping routine that verified `motionFrame` had advanced but not
   *where* the machine had stopped — it could halt mid-`buildSchedule`, where
   `statBatches` is zeroed and not yet rewritten, and report "batches 0 != 1" as
   if the builder were at fault; and importing P2's log sweeper, which swept the
   wrong directory.

The pre-existing renderer was not at fault in any of them.

---

## 21. Recommendation for P4

P4 introduces dynamic Y sorting. What P3 hands it:

1. **The main thread is the constraint now, not the executor.** `MOTION12`
   already uses ~68% of a PAL frame with twelve sprites and no gameplay. A
   sorter runs in exactly that budget. Measure it the same way — the
   `motionTick → scrollPublish` raster span — and treat `publishSkip` as the
   pass/fail signal, because it is the counter that caught the HUD cost.
   Consider also whether `regenTick`'s five rows per frame can drop to four
   (25 rows over 8 frames needs 3.2), which is free headroom P3 did not spend.

2. **Sorting is what makes the gap rule hard, not what makes it optional.** P2
   proved the `i-6` gap rule is what keeps a merged batch's reuse window free of
   sprite DMA. A sorter changes *which* entry is entry `i-6` from frame to
   frame, so the predecessor of a given logical sprite can change without that
   sprite moving at all. P3 already exercises a mild form of this — `SHAPE`
   shifts every later entry's predecessor by one when the candidate is admitted
   — and that is the fixture to generalise.

3. **Admission churn will get much worse, and there is now evidence to argue
   from.** `GAP33` shows a single sprite blinking at the threshold with no
   hysteresis. Under a sorter, order changes will move sprites across the
   threshold *without* their own Y moving. P4 should decide the hysteresis
   question explicitly, against `GAP33`'s measured behaviour, and should keep a
   fixture that walks a sprite across the boundary one raster per frame.

4. **`MAX_SCHED` is a live constraint with a working fault path.** `T6X3` sits
   exactly on 24 and `MAXCAP` overflows deliberately. A sorter that can change
   the accepted set should be tested against both.

5. **Reuse the P3 fixtures directly.** `MSBFLIP6` and `X255` qualify `$D010`
   independently of ordering, so a P4 regression on those is a P4 bug, not a
   `$D010` bug. `MOTION12` is the endurance case to keep running.

6. **The rotating ring belongs after the sorter is qualified, not with it.**
   P3 deliberately did not build it: a ring of uniquely identifiable sprites
   continuously changing Y order is the *integration* proof, and it should be
   built on a sorter that has already been qualified against deterministic
   order-change fixtures.

7. Keep `-console` for automated suites and keep manual acceptance windowed.

---

## 22. Supporting visual evidence (not a substitute for §17)

Headless screenshots taken through the monitor, as a sanity check only.

**`MSBFLIP6` (17)** — `FIX 11  ACC 0C  REU 06  MRG 00  UNS 00`, row 21
`MOV 1  MFRM 007C  OVF 00  BOV 00`. The picture is the test: the six leaders
alternate left / right of screen centre (`0 2 4` left, `1 3 5` right) and the six
reusers are the **exact mirror** (`7 9 B` left, `6 8 A` right). Every physical
slot's two sprites sit on opposite sides of X=255, so a stale `$D010` bit would
be unmissable.

**`MAXCAP` (22)** — `FIX 16  ACC 18  REU 12`, row 21 `MOV 0  MFRM 0000  OVF 06
BOV 00`, row 22 `LOG 1E`. Thirty sprites offered, twenty-four accepted, six
counted as overflow, and the fault is legible on screen rather than silent.

**`MOTION12` (23)** and **`GAP33` (20)** captured likewise; `GAP33` was caught
at `ACC 07` with seven sprites present, which is one of the two correct states.

These are single frames from a stepped machine. They cannot show flicker,
tearing, intermittency, or anything that only appears after a long dwell — which
is the entire failure class this project exists to catch. They support §17; they
do not replace it.
