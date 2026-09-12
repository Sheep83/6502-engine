# P5 — rotating-ring integration torture proof

**Verdict: AMBER.**

Fourteen of the fifteen success criteria are met, and the renderer itself is
clean under the hardest schedule this engine has ever been given. The one that
fails is criterion 11: **no P5 mode has zero publication skips.** Sixteen
sprites moved, re-sorted and rebuilt every frame, on top of the P1 scroller,
does not fit in a PAL frame with the cycles left over.

That is a main-thread capacity result, not a rendering fault, and the
distinction is precise and worth stating up front:

| | |
|---|---|
| sprite identity, geometry, slots, predecessors, pointers, colours, `$D010` | **exact, on every frame checked, in all three modes** |
| frame transaction at raster 250 | **held, 200 frames per mode** |
| scroll page / pointer-destination / back-page / sorter / overflow faults | **zero** |
| **frame-record publication** | **skipped on ~13% of frames** |

A skipped publication drops one *frame record* — fine scroll, screen page,
pointer-table destination. The record stays pending and is adopted at the next
raster 250, so the scroll hitches for one frame and catches up. **The sprite
schedule is published on a different path that has no skip branch at all**
(`publishSchedule` unconditionally sets `schedPending`), so sprites are never
dropped, never stale and never corrupted by this. What a human will see is
occasional scroll judder under a correct ring.

---

## 1. P5 architecture

P5 adds a source of logical X/Y and nothing else. The production path is
unchanged and is asserted at source level:

```
ringTick          sixteen sprites get their X/Y from the orbit      <- P5
sortTick          order logical IDs by (Y, logical ID)
buildSchedule     consume the ORDERED ids, apply the i-6 reuse rule
publishSchedule   one byte
frame IRQ         adopt CURRENT at raster 250
executor          consume CURRENT only
```

There is no ring renderer, no phase-to-slot shortcut and no special case below
`ringTick`. `tests/test_p5.py` section 1 asserts over the whole of
`src/p5_ring.asm` that it never names a VIC or SID register and never names
`schedSlot` or `MUX_FIRST_SLOT`: a hardware slot is still earned by being
accepted at a sorted position, and the sorter still has to discover the order
from Y alone. If the ring could hand the builder an order it already knew, P5
would prove nothing P4 had not.

## 2. Ring geometry

```
X = 176 + 140 * cos(2*pi*k/256)      ->  36 .. 316
Y = 140 +  70 * sin(2*pi*k/256)      ->  70 .. 210
sweep (RING-SHIFT only): triangle    -> -14 .. +14, so Y spans 56 .. 224
```

Every number is chosen against a rule, not for looks:

- **X spans 281 pixels, wider than 256**, so X=255 is crossed twice per orbit by
  every sprite, and about five of the sixteen have their MSB set at any moment.
- **Y stays inside the visible sprite band 50..229** even at the extremes of the
  sweep. The generator refuses to assemble a table that does not.
- **The orbit is an ellipse, not a circle**, because the screen is: 140 wide
  against 70 tall keeps the sprites spread over most of the playfield in both
  axes.

### The geometric fact that makes P5 watchable

Sixteen points evenly spaced in **phase** are not evenly spaced in **Y**: they
bunch at the top and bottom of the orbit where `cos(phase) ~ 0`. The obvious
worry is that the bunching starves the reuse rule — accepted entry *i* must
clear entry *i-6* by `MIN_REUSE_GAP` — so sprites start being legitimately
**rejected**, and a human watching sees one vanish and reports corruption that
was never there.

It does not happen, and the reason is worth writing down: bunching tightens
**adjacent** sorted pairs, but the reuse rule spans **six** positions, and a
six-position span always crosses the whole cluster. Measured over the full
period of every mode:

```
min( sorted_y[k+6] - sorted_y[k] )  =  43        MIN_REUSE_GAP = 33
```

So **all sixteen sprites are admitted on every frame of every mode**, and the
model asserts it (`tests/p5_model.py`, `audit()`). That is what makes P5 a
legitimate manual test: **a missing sprite is always a fault**, and the human
never has to decide whether a disappearance was the builder being correct.

## 3. Phase representation

16-bit fixed point, 8 fractional bits, one accumulator advanced per frame. The
table index is the high byte, so `phaseVel = $0100` is exactly one table step
per frame. Per-sprite phase offset is `16 * logical index` — 256/16, so the
sixteen sprites are evenly spread round the orbit and the offset is four `ASL`s.

An earlier draft used `$0040` for RING-SLOW. At a quarter-step per frame the
index only changes every fourth frame and the sprites visibly stutter, which is
worse for a manual test than it is slow. One step per frame is the smoothest
slow motion a 256-entry table can express, and that is what RING-SLOW uses.

## 4. Fixture and mode IDs

| hex | dec | name | phase vel | sweep vel | orbit | exact period |
|---|---|---|---|---|---|---|
| **`$1F`** | 31 | `RING-SLOW` | `$0100` | — | 256 f (5.1 s) | 256 f |
| **`$20`** | 32 | `RING-FAST` | `$0800` | — | 32 f (0.6 s) | 32 f |
| **`$21`** | 33 | `RING-SHIFT` | `$0100` | `$0010` | 256 f | 4096 f (82 s) |

Navigation is unchanged: SPACE steps, **M** jumps to the first P3 fixture, **S**
to the first P4, and **R** is new and jumps to `RING-SLOW`. The bottom bar reads
`FIXTURE 1F SPC=NXT M=3 S=4 R=5` — `SPACE=NEXT` was shortened to `SPC=NXT` to
pay for `R=5` within the bar's 30-character budget.

A new HUD row shows the orbit census:

```
RING ORB nnnn  UP nnnn  DN nnnn  FEL nn
```

`FEL` is `frameEntryLine` and is the one field on screen that must never change:
`FA` is raster 250. A human can watch that single field and know the FIX 16
invariant still holds.

## 5. Motion implementation

The orbit is precomputed into `src/p5_tables.asm` as **absolute screen
coordinates** — `ringXLo`, `ringXHi`, `ringY`, `ringShiftTab`, 1 KB at `$2400`,
the hole between the sprite bitmaps (`$2000-$23FF`) and screen page B
(`$2800`). Nothing ever points the VIC at it; sprite pointers only ever hold
`$80..$8F`.

Per sprite, per frame: an index add and three table reads. **No multiply, no
trig, no fixed-point scaling at run time** — about 30 cycles a sprite, 1,440
cycles for all sixteen including loop overhead. That matters because P5 exists
to measure the sorter and the builder; motion that cost real time would show up
in those measurements as if the renderer were expensive.

The tables are generated by `tools/gen_p5_tables.py` from `tests/p5_model.py`,
with `--check` drift detection wired into the suite. They are generated rather
than computed in KickAssembler because the model and the engine must agree byte
for byte — every P5 expectation is a table lookup — and KickAssembler's rounding
is Java's while Python's `round()` is banker's rounding. `_round()` is defined
once, in the model, as `floor(x + 0.5)`.

### The sweep is a triangle, and it starts at zero

A sine lingers at its extremes and hurries through the middle, which would
sample some raster offsets far more than others; the point of the sweep is to
move the batches through **every** raster relationship, so it sweeps uniformly.

It is also phased so that index 0 is **zero**, which is not cosmetic. RING-SLOW
and RING-FAST have no sweep, so their accumulator sits at index 0 forever. The
first draft's triangle began at `-SHIFT_AMP`, and those two modes silently
orbited fourteen rasters above RING-SHIFT's centre — the three modes no longer
shared one geometry, which is the entire basis for attributing a difference
between them to phase velocity. It was caught by the model comparison on the
first run, as a uniform `-14` on every Y.

## 6. Sorter integration

Unchanged from P4, and that is the point. `sortTick` receives sixteen logical
IDs whose Y values change every frame and returns the unique ascending order
under the total-order comparator `(Y, logical ID)`.

The suite reads `sortedIDs` out of the engine on **every** frame it steps and
compares it against the comparator computed independently in Python. Measured
churn, over the frames walked:

| mode | distinct sorted orders | reorder frames (model, full period) | max Y step / frame |
|---|---|---|---|
| `RING-SLOW` | 10 in 40 f | 57 / 256 | 2 |
| `RING-FAST` | 32 in 40 f | 31 / 32 | 14 |
| `RING-SHIFT` | 10 in 40 f | 927 / 4096 | 3 |

`RING-FAST` reorders on 31 of every 32 frames — the sorted order is essentially
never the same twice.

## 7. Equal-Y ties

The orbit produces exact integer ties constantly, from rounding alone: **240 tie
pairs per orbit** in RING-SLOW and RING-FAST, **3,840** over RING-SHIFT's
period. The suite does not merely count them — `walk()` compares the engine's
`sortedIDs` against the documented comparator on every frame, so every one of
those tie frames is a check that the tie resolved by ascending logical ID.

Result: **no one-frame identity swap, in any mode, on any frame checked.**

## 8. X=255 and `$D010`

`ringX255Up` / `ringX255Down` are counted **by the 6502**, as it writes `logXHi`,
not predicted by the model. That makes them the machine's own statement that its
X really crossed 255, and they are then compared against the model:

| mode | frames | engine up / down | model up / down |
|---|---|---|---|
| `RING-SLOW` | 3,379 | 211 / 211 | 211 / 211 |
| `RING-FAST` | 8,787 | 4,393 / 4,394 | 4,393 / 4,394 |
| `RING-SHIFT` | 6,092 | 381 / 381 | 381 / 381 |

**Exact, in both directions, in all three modes.** Every one of HW2..HW7 was
observed in **both** X-MSB states, and the complete per-batch `$D010` is compared
against the model on every frame walked.

One bug was found here and fixed: the census counted five spurious upward
crossings at fixture load, because `ringPlace` compares each new MSB against
`logXHi`, which still held the previous fixture's values. Placement is not
motion; the counters are now zeroed *after* the initial placement.

## 9. Same-slot predecessor churn

| mode | distinct (sprite, i-6 predecessor) pairs | logical owners per slot HW2..HW7 |
|---|---|---|
| `RING-SLOW` | 134 | 16, 16, 16, 16, 16, 16 |
| `RING-FAST` | 131 | 16, 16, 16, 16, 16, 16 |
| `RING-SHIFT` | 134 | 16, 16, 16, 16, 16, 16 |

**Every one of the six hardware slots is owned by all sixteen logical sprites
within a single orbit.** Identity and slot are completely decoupled, continuously,
and the i-6 predecessor *identity* changes underneath the reuse rule while the
rule stays legal — `compare_sched` checks the predecessor's logical ID on every
frame, not merely that some predecessor existed.

## 10. Batch-shape churn

Batch count moves between **6, 7 and 11**; the sampled walks saw 2–3 distinct
shapes per mode and the model sees 3 over a full period. RING-SLOW and
RING-SHIFT visit **69 and 126 distinct mid-screen batch rasters** respectively.

**Minimum inter-batch spacing is 1 raster** — denser than `MAXCAP`, the fixture
that exposed the FIX 16 bug, and dense enough that the executor's late-recovery
path is exercised continuously rather than rarely. The executor remains
decision-free: it reads CURRENT and nothing else.

## 11. Frame transaction at raster 250

The FIX 16 invariant, under that density:

```
RING-SLOW   200 frames, every one entered at 250
RING-FAST   200 frames, every one entered at 250
RING-SHIFT  200 frames, every one entered at 250
```

No mid-frame frame transaction, and the late-recovery chain never runs away into
one — which is exactly the failure FIX 16 was.

## 12. Pointer and colour semantic integrity

`check_presentation_late()` (the P4 flicker regression) ran 60 consecutive frames
per mode: the live sprite-pointer table still matches CURRENT after the whole
main-thread pass, in every mode.

P5 also closed a real gap. `compare_sched` checked identity, geometry, slots,
predecessors and `$D010` — but **never colour**. On a fixture whose entire
premise is "sixteen sprites you can tell apart", a sprite wearing another
sprite's colour is precisely the fault a human would report, so `walk()` now
compares `schedCol` for every accepted entry against the colour its logical ID
is supposed to have. Verified zero mismatches.

Worth recording: **sixteen sprites, fifteen colours.** Black is the background,
so the C64 has only fifteen usable sprite colours and one must be shared —
logical 11 and 15 are both medium grey. That is a hardware limit, not an
oversight, and it is why the **numeral** is the identity in this fixture and the
colour is corroboration. The sixteen bitmaps really are distinct; the colours
cannot be.

## 13. Scrolling, pages and fine phases

Run under the ring, not simplified for it:

| mode | frames | coarse | flips | page A / B | fine phases |
|---|---|---|---|---|---|
| `RING-SLOW` | 6,584 | 823 | 823 | 3,295 / 3,289 | all 8, 823 each |
| `RING-FAST` | 9,870 | 1,234 | 1,234 | 4,935 / 4,935 | all 8, 1,233–1,234 |
| `RING-SHIFT` | 9,645 | 1,206 | 1,206 | 4,822 / 4,823 | all 8, 1,205–1,206 |

Zero `$d018`/software-page mismatches, zero pointer-destination mismatches, zero
back-page-late events, zero sorter faults, zero schedule overflow, zero batch
overflow — in every mode.

## 14. Badline sweep

`RING-SHIFT` sweeps the whole orbit ±14 rasters on a uniform triangle, which
moves every batch through **126 distinct mid-screen raster lines** and therefore
through all eight badline phases repeatedly, while the Y-order churn continues
underneath. No raster-position-dependent fault appeared: the frame transaction
stayed at 250 and presentation stayed coherent across the entire sweep.

## 15. Executor timing

```
                 frame batch (raster 250)     mid-screen invocations
                 min / med / max              min / med / max
RING-SLOW        840 / 861 / 914              279 / 338 / 1051
RING-FAST        839 / 868 / 922              289 / 422 /  830
RING-SHIFT       847 / 865 / 914              279 / 338 / 1347
```

These need reading carefully, and the naive reading is wrong.

**The frame batch is not a six-entry sprite batch.** It is the whole frame
transaction — `$d011`, `$d018`, the pointer destination, `$d015`, the
diagnostics, schedule adoption — *plus* batch 0's six entries. P2's qualified
646 cycles is for a six-entry **mid-screen** batch, and the 756-cycle display
deadline applies to mid-screen batches, which must finish before the beam
reaches the sprites they program. The frame batch runs at raster 250, below the
display window, with the whole vertical blank ahead of it. At ~900 cycles it is
comfortable.

**The mid-screen invocations above 756 cycles are chains, not overruns.** The
cost distribution is multimodal in steps of about 280 cycles — one batch:

```
RING-SHIFT   200s 4926 | 300s 6094 | 400s 894 | 600s 3369 | 700s 298 | 1000s 1097 | 1300s 14
```

and `maxLateRun` is 6. Those are the late-recovery path executing two to four
batches back-to-back inside one interrupt, which is what the path exists for and
what a 1-raster minimum batch spacing guarantees will happen. 6.4% (RING-SLOW)
to 7.5% (RING-SHIFT) of mid-screen invocations chain. **No single batch exceeds
its deadline**, and section 11 proves the chain never runs into the frame
transaction.

So the P2 qualified six-entry critical path of 646 cycles is **not** exceeded by
P5, and no new worse case was found for it.

## 16. Main-thread timing

Median elapsed cycles per segment. These are raster-derived **elapsed spans and
include the raster IRQs that interrupt them** — which is the number that decides
whether preparation fits in a frame. It is not the main thread's own cycle
count; the difference is the executor running on top of it.

| | ring | sort | build | regen | **sum** | of 19,656 |
|---|---|---|---|---|---|---|
| `CROSS6` (P4, 12 sprites, clean) | 585 | 884 | 4,028 | 4,045 | **9,566** | 48.7% |
| **`RING-SLOW`** | 1,440 | 1,128 | 9,047 | 4,644 | **16,283** | **82.8%** |
| **`RING-FAST`** | 1,453 | 1,520 | 7,570 | 5,924 | **16,491** | **83.9%** |
| **`RING-SHIFT`** | 1,440 | 1,128 | 8,927 | 5,803 | **17,322** | **88.1%** |
| `SORTCAP` (P4, 26 sprites, "the ceiling") | 897 | 2,399 | 11,069 | 3,361 | **17,750** | **90.3%** |

All three ring modes sit in `SORTCAP` territory — the level P4 already named as
the main thread's ceiling.

**`build` dominates**, and part of it is not builder work: the span is elapsed,
so the eleven batches' worth of executor IRQs are charged to it. That is visible
in the modes themselves — RING-SLOW's build (9,047) is *larger* than
RING-FAST's (7,570) despite identical geometry, because RING-SLOW reaches
11-batch frames and RING-FAST stays at 6–7.

The sorter is **not** the problem: 1,128–1,520 cycles, about 7% of preparation,
exactly as P4 measured. Nor is the ring: 1,440 cycles for sixteen sprites.

## 17. Remaining frame-budget reserve

**There is essentially none, and that is the headline number for P6.**

At the median, preparation consumes 83–88% of a PAL frame, leaving roughly
**2,300–3,400 cycles**. On the worst frames it exceeds the frame entirely, which
is what the publication skips are.

Two honest caveats about the measurement:

- A span is `(end - start) % 19656`, so a span that exceeds a whole frame **wraps
  and reads as a small number**, and a mismatched pair reads as nearly 19,656.
  A bare `max()` over the raw spans reported 19,655 — `PAL_FRAME - 1` — and
  called it "100.0% of the frame". The suite now discards implausible pairs and
  reports the median, and this report quotes the segment sums, which are robust
  and which reproduce `CROSS6`'s independently measured span to within 3 cycles.
- The figure includes the **diagnostic HUD and the back-page regeneration**.
  `regen` alone is 4,644–5,924 cycles — 24–30% of the frame — and is pure
  background scenery, not the renderer under test. A game that regenerated less,
  or less often, would recover most of it. P4 measured `ROWS_PER_TICK` 5→4 twice
  and found no improvement, so that particular lever is known not to work; the
  cost is in the total, not the peak.

Before adding a player layer, collision, a real HUD or the border opening, the
main thread needs cycles that P5 shows are not currently there.

## 18. Publication skips

The true rate, measured over windows short enough that the counter cannot
saturate:

| mode | skips | frames | rate |
|---|---|---|---|
| `RING-SLOW` | 18 | 131 | 13.7% |
| `RING-FAST` | 16 | 105 | 15.2% |
| `RING-SHIFT` | 17 | 137 | 12.4% |

**`publishSkip` saturates at 255**, and that fooled this suite — and me — twice.
A delta taken across a long run reads as *zero* the moment the counter is
already pinned, and section 8 duly reported "ZERO publication skips" for two
modes that were skipping one frame in seven. The suite now zeroes the counter
before the window and **fails separately if it saturates**, so the number can
never again be trusted wrongly. This is the same class as the 16-bit histogram
wrap found during the FIX 16 work: a green instrument that was wrong.

The mechanism is P3's, unchanged: the preparation pass straddles raster 250, so
one pass publishes late and the next publishes again before the frame IRQ has
adopted the first.

## 19. Independent model

`tests/p5_model.py` states the geometry, the phase arithmetic, the sweep, the
comparator and the expected schedule **from the rules**, never read back from the
6502. It generates the engine's tables, so the two cannot drift, and
`--check` fails the build if they do. `audit()` asserts, over every frame of
every mode's full period, that all sixteen sprites are admitted, that the reuse
gap holds, that X=255 is crossed both ways, that ties occur, that every slot has
several owners, and that Y never leaves the visible band.

`census()` counts the churn exhaustively over full periods — that is why the
report can quote "134 distinct predecessor pairs" and "3,840 tie pairs" without
the engine paying a cycle to count them. Only what the model *cannot* know — that
the engine's own X really crossed 255 — is counted in 6502.

## 20. Visual and headless checks

A headless pixel checker was built (`p5vis.py`, exploratory tooling, not wired
into the suite) that composites the expected sprite layer from the model —
including **hardware sprite priority**, since ring sprites overlap and a naive
"every set bit must be its own colour" test cannot tell a fault from legitimate
occlusion, exactly as the brief warns.

It is reported here as **inconclusive**, honestly. It reached ~80–88% agreement
and left a residual concentrated on the six entries programmed by batch 0, which
are one frame further along than the mid-screen batches at the instant a
screenshot is taken; a single global pipeline lag cannot fit both groups. One
identity read 0% at both lags, which looked alarming until checked directly —
and the direct check was clean:

```
id11 (logCol 12) at X=296 Y=176 -> (148,148,148) x 242   correct colour, correct place
id15 (logCol 12) at X=104 Y=200 -> (148,148,148) x 206   correct colour, correct place
```

242 pixels is id11's entire bitmap. Both sprites are on screen, in the right
colour, where the model puts them; the 0% was a bug in the scoring harness. The
register-level proof is exhaustive and the direct sample confirms it, so the
pixel checker's disagreement is tooling, not evidence — and per the brief,
**manual observation remains authoritative.**

A full-resolution capture of `RING-SLOW` shows all sixteen numerals present and
distinct: `4 5 6 7 3 8 2 9 1 A 0 B F E D C`.

## 21. Soak results

`RING-SHIFT`, the mode with the longest exact period (4,096 frames), so a
20,000-frame soak covers nearly five complete cycles of every deterministic
state the fixture can reach.

```
20,064 frames, 8,200 motion frames, 32 orbits, 2,507 coarse steps
X=255 crossings: 512 up, 513 down

ok   the soak really ran                           20,064 frames
ok   frame transaction never left raster 250       frameEntryLine 250
ok   zero $d018 / software-page mismatches         0
ok   zero pointer-destination mismatches           0
ok   zero back-page-late events                    0
ok   zero sorter faults                            0
ok   zero schedule overflow                        0
ok   zero batch overflow                           0
ok   all sixteen sprites still accepted            16
FAIL zero publication skips                        255 (saturated)
```

Every renderer invariant survived 20,064 frames. The only failure is the known
publication-skip result of section 18.

## 22. P0-P4 regression

```
tests/test_p0.py   ALL PASS
tests/test_p1.py   ALL PASS
tests/test_p2.py   ALL PASS
tests/test_p3.py   ALL PASS
tests/test_p4.py   ALL PASS
```

**P5 broke P1, and P1 caught it.** `HUD_ROW_P5 = 20` was added to `hudRowList`
in `src/main.asm` but not to the *second* place the same set is stated — the
compare chain in `renderRow` (`src/scroll.asm`) that decides which rows the
back-page regeneration must leave alone. Row 20 was regenerated as a world row
and then overwritten by the HUD, and `test_p1` failed on exactly the two things
it exists to check: every displayed row printing its own world row number, and
every displayed row belonging to the same page.

There turned out to be a **third** copy of the set, `HUD_ROWS` in
`tests/test_p1.py`. All three are now correct and all three now carry a comment
naming the other two, because nothing in the build makes them agree.

One further P4 failure — "an overflowing build never writes outside its own
buffer" — appeared only when P4 was run concurrently with another suite
competing for the host CPU, and passes cleanly when run alone. It is contention
in my own harness, not a regression. The P0-P4 ladder must be run without
competing jobs.

## 23. FIX 16 regression

`tests/test_p4.py` section 9c (`frameEntryLine == FRAME_IRQ_LINE` on `MAXCAP`
and `SORTCAP`) passes. P5 section 6 extends the same invariant to all three ring
modes, under a schedule denser than the one that originally exposed the bug:
**200 frames per mode, every one entered at raster 250.**

## 24. P5 regression

`tests/test_p5.py`, eleven sections: model and table-drift agreement,
frame-by-frame engine-versus-model comparison of positions, sorted order, the
complete schedule, colours and `$D010`; equal-Y ties; churn of order, slot
ownership, predecessor identity and batch shape; the X=255 census against the
engine's own counters; the raster-250 invariant; late-frame presentation;
scrolling, pages and fine phases; main-thread timing; and an optional soak.

## 25. Fast development regression

```sh
make test-fast
```

`tests/p5_model.py` audit, table drift check, then `tests/test_p5.py --fast`:
30 frames per mode of full engine-versus-model comparison, the raster-250
invariant, late-frame presentation, and a short scroll run. No soak, no long
free-runs. Deliberately quick, because a regression suite nobody runs is worse
than none.

Frame counts are modest on purpose. The exhaustive proof of the geometry is the
**model's**, which audits every frame of every full period for free; what the
machine must demonstrate is that it *implements* that model. An earlier draft
walked 140 frames per mode and took fourteen minutes a mode.

## 26. Full qualification regression

```sh
make test-full
```

The whole P0–P4 ladder including the FIX 16 regression, then `test_p5.py` with a
20,000-frame soak of `RING-SHIFT` — the mode with the longest exact period
(4,096 frames), so a 20,000-frame soak covers nearly five complete cycles of
every deterministic state.

## 27. Manual dwell instructions

Run windowed (`make run`), then press **R** for `RING-SLOW`, SPACE for the rest.

**`FIXTURE 1F` — RING-SLOW.** Several minutes at normal speed. Expect sixteen
sprites `0`–`F`, each in its own colour (11 and 15 are both medium grey — the
C64 has only fifteen), orbiting smoothly, one orbit every ~5 seconds, passing
over and under each other continuously. Watch for: a missing numeral, a repeated
numeral, a numeral in the wrong colour, a sprite jumping horizontally as it
crosses the middle of the screen (X=255), a sprite flickering as two cross in Y,
and any sprite fragment or garbage. **`FEL` on the RING row must read `FA` at all
times.** `ACC` must read `10`.

Expect to see occasional scroll judder. That is the publication skip described in
section 18 and it is the known AMBER. The *sprites* must remain perfect through
it.

**`FIXTURE 20` — RING-FAST.** Same correctness, eight times the speed. Scroll
judder is expected to be at least as visible. No sprite garbage is acceptable at
any speed.

**`FIXTURE 21` — RING-SHIFT.** Run for at least two minutes so the orbit sweeps
its full ±14 rasters (an 82-second period). Watch specifically for anything that
appears only at particular vertical positions: a glitch that comes and goes as
the ring drifts is a badline or raster-position fault.

**P5 is not declared manually GREEN here. That is yours to give.**

## 28. VICE and process hygiene

`pgrep -fl x64sc` before the suite; every launch retains its exact PID and is
terminated and reaped in `finally`, on success, failure and timeout; the suite
verifies no test-owned VICE remains. Every automated launch uses `-console`, so
no window is mapped and no keyboard focus is taken. No broad `pkill`, no
`open -a`. Transient screenshots and traces went to the session scratchpad and
`/tmp`, never into the repository.

## 29. Disk usage

```
du -sh build/     68K      only the current binary and symbols; no per-run dirs
du -sh .          2.1M     the whole repository
/tmp/6502-engine-p4        0 files: every trace log swept after its VICE was reaped
```

P5 adds 1 KB of generated tables to the binary and one new source file. No
per-run artefacts accumulate anywhere.

---

## What P5 leaves for P6

The renderer is not the constraint. The sorter is 7% of preparation and the ring
motion is 1,440 cycles; what fills the frame is `buildSchedule` (charged with the
executor IRQs that interrupt it) and the back-page regeneration, which is
scenery. Before a player layer, collision, a real HUD or the border opening can
be added, the main thread needs cycles that P5 shows are not there.

P5 deliberately does **not** attempt that work. `ROWS_PER_TICK` is the obvious
lever and P4 measured it twice and found it does not help, so the next step is a
measurement question rather than an optimisation to reach for, and it should be
taken on its own evidence rather than bolted onto a qualification checkpoint.
