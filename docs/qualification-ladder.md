# Qualification ladder

Each checkpoint is proven by deterministic fixtures **and** by a human watching a
non-warp run before the next is started. Each remains independently runnable —
P1 does not replace P0. Any smallest failing fixture is kept permanently.

| | checkpoint | status |
|---|---|---|
| **P0** | static screen + static pre-sorted sprites | **implemented** |
| **P1** | scrolling screen + static pre-sorted sprites | **implemented** |
| **P2** | deterministic static-Y stress matrix + scrolling | **implemented** |
| **P3** | scripted moving Y positions, externally predetermined | **implemented** |
| **P4** | dynamic Y sorter | **implemented** |
| **P5** | generic logical sprite input — the rotating-ring torture proof | **implemented, AMBER** |
| P6 | fixed player base + second player layer | not started |
| P7 | collision / fire integration | not started |
| P8 | top-border HUD + border-opening / handoff timing | not started |
| P9 | terrain / turret interaction | not started |
| P10 | real wave / gameplay integration | not started |

## What P5 found

P5 puts sixteen uniquely identifiable sprites on one orbit and runs the whole
ladder at once: continuous motion, continuous Y-order churn, exact equal-Y ties,
X=255 crossings both ways, every hardware slot owned by every logical sprite,
batch shape changing continuously, and the scroller underneath.

The renderer holds. Positions, sorted order, accepted identity, slots, `i-6`
predecessor identity, batch geometry, colours and `$D010` match an independent
model exactly, on every frame checked, in all three modes; the frame transaction
stays at raster 250 under a schedule with **one-raster** minimum batch spacing;
and a 20,000-frame soak recorded zero renderer faults of any kind.

**What P5 found is the main thread.** Sixteen sprites moved, re-sorted and
rebuilt every frame costs 83-88% of a PAL frame at the median, and the worst
frames exceed it — so the *frame record* publication is skipped on roughly one
frame in eight. Sprites are unaffected (that publication path has no skip
branch); the visible symptom is scroll judder. The sorter is not the cause at
~7% of preparation, and neither is the ring motion at 1,440 cycles.

There is essentially **no CPU reserve left** for P6's player layer, collision,
HUD or border opening. That number, not the ring, is the checkpoint's real
output. See `reports/p5-rotating-ring-torture.md`.

## The final integrated target

Not a gameplay demo. An intentionally **synthetic** proof, harder than ordinary
play, that can be started and simply watched for a long non-warp run:

> a PAL C64 continuously scrolls the double-buffered playfield, executes the
> top-border opening and six-sprite HUD timing, and displays the chosen maximum
> gameplay sprite geometry through deterministic multiplexing with no
> corruption, flicker, missed scroll publication or register-ownership ambiguity.

with deterministic sprite patterns, predetermined Y movement, continuous
scrolling, every fine-scroll phase, repeated coarse page flips, and no
dependence on player skill or random encounters.

## What P1 decided

P1 introduced the second screen page, and with it the one genuine tension in
this architecture: **two sprite-pointer tables** (`$07f8` for page A at `$0400`,
`$2bf8` for page B at `$2800`).

"Write both tables every time" was **not** adopted. The shape implemented is:

```
frame chooses the active screen
      -> renderer establishes ONE pointer-table destination for that frame
      -> every sprite pointer write that frame targets that page
```

**Mechanism: a single patched operand byte.** `$07f8` and `$2bf8` share the low
byte `$f8`, so the executor's one pointer store — `sta PTR_A,x`, labelled
`exPtrStore` — needs only its HIGH byte rewritten. The frame IRQ writes that one
byte, once, at the same instant it writes `$d018`. A raster batch therefore
cannot choose a destination even in principle: there is exactly one store
instruction in the whole program, and its target is already fixed before the
first batch of the frame runs.

`tests/test_p1.py` asserts all of this: one `sta $d018` in the source, one
pointer store, one writer of `exPtrStore+2`, and zero page/pointer mismatches
over a 23,000-frame run.

## What P4 decided

A **persistent insertion sort** over logical sprite IDs, keyed on
`(Y, logical ID)`. See `docs/p4-dynamic-y-sorter.md` and
`reports/p4-dynamic-y-sorter-report.md`.

**The comparator being a TOTAL order is the whole argument.** Logical IDs are
unique, so no two elements compare equal, so there is exactly one ascending
arrangement — and a persistent sort therefore converges to it regardless of the
arrangement it started from. Persistence affects cost, never result. Without the
tie-break the order would be partial and the output would depend on last frame's
accident, which matters because P2's merged batches ARE groups of equal-Y
sprites.

A distribution/bucket sort was rejected: it pays a fixed clear-and-walk cost
every frame regardless of how little moved, and after P3 the main thread is the
scarce resource. Selection sort was rejected as O(N²) always.

**Two capability limits were measured for the first time**, and neither is the
sorter's fault (the sorter is ~7% of the preparation span):

- **Batch density.** The builder has a rule for how close two sprites sharing a
  slot may be, and **none** for how close two consecutive mid-screen *batches*
  may be. Geometry putting batches 3 rasters apart made the executor's
  late-recovery path chain batches inside one interrupt — 17 sprite writes in
  one invocation, 1078 cycles, and a frame IRQ eventually serviced at raster 194
  instead of 250. Left for the next checkpoint; P4 did not change admission
  policy to hide it.
- **Main-thread ceiling.** 26 logical sprites re-sorted and rebuilt every frame
  exceeds the budget and produces publication skips, even at the cheapest
  possible batch layout. P4 is the first checkpoint to rebuild that many per
  frame — P3's 30-sprite MAXCAP was static and built once. Twelve moving,
  crossing sprites are comfortable: 20,000+ frames clean at ~78% of a frame.

That ceiling is the number the rotating-ring checkpoint should be planned
against.

## What P3 decided

P3 fed **moving** logical X/Y through the P0–P2 builder without changing the
renderer's shape. See `docs/p3-scripted-motion.md` and
`reports/p3-scripted-motion-report.md`. Three decisions are worth carrying
forward:

**Admission is stateless — no hysteresis.** A sprite whose reuse gap oscillates
across `MIN_REUSE_GAP` is admitted and rejected on alternate frames and
therefore blinks. That is the correct result of the documented rule applied to
the current frame's geometry, and P3 makes it observable (`GAP33`) rather than
papering over it. Inventing a policy around it is a later decision that should
be made against this evidence, not instead of it.

**`$D010` is now real.** P0–P2 were entirely X < 256, so the builder's
`$D010` pass only ever cleared bits. It now sets and clears per entry, which is
what makes physical slot reuse safe across an MSB change — the slot's bit is
rewritten from the new owner every batch, so no stale bit can survive.

**Motion belongs in main-thread preparation, and the executor was not touched.**
The executor's critical path is byte-for-byte the P2 cost at every batch size.
What P3 *did* cost was main-thread time, and that is where the one real defect
appeared: drawing all five diagnostic HUD rows every frame pushed per-frame
preparation to 74.6% of a PAL frame, passes began straddling the frame boundary,
and `publishSkip` became non-zero — a one-frame scroll stutter. Redrawing one
HUD row per frame fixed it. **The main-thread budget is now the scarce resource,
not the raster executor.**

## What P2 decided

Nothing structural, as planned. P2 swept sprite geometry against the scroller P1
built; see `docs/p2-static-y-matrix.md` and
`reports/p2-static-y-stress-matrix-report.md`.

The gap P1 left was that its fixtures never produced a **merged mid-screen
batch** — every mid-screen batch was one entry, so `REUSE_LEAD` was sized for a
six-entry merge that no fixture generated. P2 built that fixture (`T6`,
fixture 5: six leaders at Y 60..65, six reusers all at Y 98) and measured it.

**`REUSE_LEAD` stays at 12.** The six-entry merged batch costs **646 cycles** to
its last register write in the worst fine-scroll phase, against a 756-cycle
budget: a margin of **110 cycles**, and it also clears the stricter 693-cycle
sprite-fetch deadline. The budget was argued; it is now measured.

Two structural facts came out of the measurement and belong here rather than in
a report appendix:

- **A merged mid-screen batch never competes with sprite DMA.** The acceptance
  rule requires `Y_i - Y_(i-6) >= 33`, so the batch fires at `Yc-12`, at least
  one line after the last predecessor stopped displaying, and its own sprites
  are not fetched until `Yc-1` — which is the deadline anyway. Badline theft is
  the only variable, which is why the phase sweep is the experiment that matters.
- **Cost is set by badlines inside the CRITICAL PATH, not inside the nominal
  12-line window.** Phases 0, 1 and 6 each have two badlines in the window and
  still cost the minimum, because the second falls after the last register write
  (or, for phase 6, on the entry line before the handler runs). Only phase 7 has
  two inside the path, and it is the only phase that costs 646 rather than 603.
