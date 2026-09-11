# P4 — dynamic Y sorter

**Implemented.** Measured results are in `reports/p4-dynamic-y-sorter-report.md`.

P4 puts a sorter between moved logical state and the schedule builder, so
logical sprites may cross in Y and change order frame to frame. It is **not**
the integrated rotating-ring proof; that is the next checkpoint, and it is
deliberately kept separate so a sorter bug and an integration bug cannot be
confused for one another.

## Where it sits

```
motionTick        logical sprites get their final X/Y for this frame
sortTick          order logical IDs by Y              <- P4
buildSchedule     consumes the ORDERED ID list, applies the i-6 reuse rule
publishSchedule   one byte
frame IRQ         adopts CURRENT
executor          consumes CURRENT only
```

Nothing is sorted after admission. No reuse decision is made on unsorted order.
The executor neither sorts nor inspects logical state — asserted at source level
over the whole handler body.

## Three identities, kept apart

| | |
|---|---|
| **logical sprite ID** | stable for the life of a fixture; indexes `logY`/`logX`/… |
| **sorted position** | where that sprite currently sits in Y order |
| **accepted index** | its position in the schedule, which sets its physical slot (`MUX_FIRST_SLOT + accepted mod 6`) and its same-slot predecessor (`accepted - 6`) |

A sprite moves between sorted positions freely without changing identity, so it
may have a different predecessor next frame, land on a different hardware slot,
appear in a different batch, or be accepted one frame and rejected the next.
**Array position is never identity.** The logical arrays are never physically
reordered; `sortedIDs` is a permutation laid over the top, and `schedId` records
which logical sprite each accepted entry actually is.

## The comparator is a total order

```
a before b  <=>  logY[a] < logY[b]  or  (logY[a] == logY[b] and a < b)
```

Logical IDs are unique, so no two elements ever compare equal: the order is
**total**, and a totally ordered set has exactly **one** ascending arrangement.

That single fact is the whole argument for using a *persistent* sort. The array
`sortTick` starts from is last frame's answer, but the array it finishes with is
the unique correct order for this frame's Y values regardless of what it started
from. **Persistence affects only how much work is done, never the result** —
which is exactly what the equal-Y policy requires, and it is tested by
scrambling `sortedIDs` behind the engine's back (identity, reversed, rotated,
pairwise-swapped) and checking it converges to the same list every time.

Without the tie-break, equal-Y sprites would compare equal, the order would be
partial, and the output would depend on last frame's accident. P2's merged
batches are precisely groups of equal-Y sprites, so that would have been a real
bug rather than a theoretical one.

## Sorter choice

| candidate | why not / why |
|---|---|
| **distribution / bucket over the 256 Y values** (Armalyte-style) | pays a fixed clear-and-walk cost **every frame regardless of how few sprites moved**. With the main thread already the scarce resource after P3, a multi-thousand-cycle floor is the wrong shape for a list that is usually already correct. |
| **selection sort** | O(N²) always — predictable and always expensive. For 26 sprites that is ~325 comparisons every frame, for nothing. |
| **persistent insertion sort** ✅ | O(N + inversions). Sprites move a few rasters per frame, so the incoming list is the answer or within a couple of adjacent swaps of it: one comparison per element and no shifts at all. |

The price is an O(N²) worst case when the incoming order is far from correct,
which happens on exactly one event — loading a fixture whose logical storage
order is deliberately scrambled. That cost is measured and reported rather than
assumed away.

`sortWork` counts shifts, so any frame's cost is visible after the fact:
`sortWork == 0` is the engine's own statement that the order was already correct
on entry.

## Output contract

```
sortedIDs[0 .. sortedCount-1]   logical sprite IDs, each exactly once
logY[sortedIDs[i]] <= logY[sortedIDs[i+1]]
ties broken by ascending logical ID
```

**Visibility: P4 has none.** Every logical sprite is sorted and offered to the
builder, so `sortedCount` is always `logCount`. If culling is ever added it
belongs *between motion and sorting* — select the visible set, sort that — and
`sortedCount` becomes the size of the selected set. Nothing downstream changes,
which is why the contract is written in terms of `sortedCount` and not
`logCount`.

## Integrity diagnostics

`sortTick` only ever **moves** entries that were already in the array, so it
cannot invent or lose an ID, and it terminates ordered by construction.
Duplicates, missing IDs and out-of-order pairs are therefore structural
impossibilities absent memory corruption, and paying O(N) every frame to
re-check them would spend the scarce resource on reassurance.

So the engine checks only what is free — that `sortedCount` still matches
`logCount` — and sets the saturating `sortFault` if not. `tests/test_p4.py`
reads `sortedIDs` directly and verifies **all** of it exhaustively (permutation,
ordering, tie rule) on every frame it inspects, at zero cost to the engine.
`sortWork` is exposed for timing analysis and shown on screen.

## Admission is still stateless

Unchanged from P3: admission is a deterministic function of **this frame's**
sorted, moved geometry, with no hysteresis. P4 makes the consequence sharper —
a sprite can now be rejected because *somebody else* crossed ahead of it and
changed its same-slot predecessor, without its own Y moving at all. `SORTSHAPE`
exists to make that observable rather than to hide it. The three outcomes must
never be conflated:

| what you see | what it is |
|---|---|
| sprite absent while `ACC` says it was rejected | correct |
| sprite absent while `ACC` says it was accepted | **renderer failure** |
| sprite present while `ACC` says it was rejected | **stale sprite: failure** |

## A limit P4 thought it found — and what it actually was

P4 reported a **batch-density limit**: the builder has a rule for how close two
sprites *sharing a slot* may be (`MIN_REUSE_GAP`) and none for how close two
consecutive mid-screen *batches* may be. The first `SORTCAP` draft — 30 sprites
at pitch 7, each swinging ±4 — put consecutive batches as little as 3 rasters
apart while a single-entry batch takes about 5 to execute, and the executor's
late-recovery path then chained batch after batch inside one interrupt: 17
sprite writes in one handler invocation, 1078 cycles, and eventually a frame
IRQ serviced at raster 194 instead of 250. P4 called that an admission gap and
left it for a later checkpoint.

**That diagnosis was wrong in its mechanism**, and the later FIX 16 / MAXCAP
forensic found the real one. `irqHandler` acknowledged `$d019` once, on entry,
and armed the next raster compare several lines later. A batch costs about five
raster lines, so whenever batches are armed closer together than that, the beam
crosses the freshly armed line *while the handler is still running* — after the
acknowledge. Nothing cleared that latch, so the `rti` re-entered the handler
immediately; and at the end of a frame `exArmFrame` has already set `curBatch`
to 0, so the re-entry ran the whole frame transaction mid-display. That is where
"a frame IRQ serviced at raster 194" came from. It was never admission.

The fix is six cycles in `exArm`: acknowledge **before** arming, and count
equality as late. Density is what *exposes* the bug, which is why dense
fixtures tripped it and sparse ones never did — but it is not the cause.
**No batch-spacing admission rule was needed and none was added.** `MAXCAP` now
runs nineteen batches armed six rasters apart with a pixel-perfect display.

`reports/fix16-maxcap-visual-corruption-forensic.md` has the measurements.
`tests/test_p4.py` section 9c pins the invariant that was missing: the frame
transaction must always run at `FRAME_IRQ_LINE`.

The `SORTCAP` re-shaping described below still stands on its own merits — it
makes the fixture test capacity rather than density, which is what P4-G asks.

## Fixtures

| # | name | what it pins down |
|---|---|---|
| 24 | `SORTSTATIC` | deliberately scrambled logical storage order, with equal-Y ties |
| 25 | `CROSS2` | two sprites crossing through an exact tie; each visits both slots |
| 26 | `CROSS6` | six interleaving sprites over six static reusers |
| 27 | `PREDCHANGE` | a crossing changes a reuser's `i-6` predecessor **identity** |
| 28 | `SORTSHAPE` | a crossing changes **admission** for a sprite that never moved |
| 29 | `TIE6` | six equal-Y sprites, block-swapped in storage, → merged batch |
| 30 | `SORTCAP` | dynamic ordering at and over `MAX_SCHED` |

Records in `src/p4_fixtures.asm` are **generated** from `tests/p4_model.py` by
`tools/gen_p4_fixtures.py`; `make test-p4` fails if they drift apart.
