# P3 — scripted motion

**Implemented.** Measured results are in `reports/p3-scripted-motion-report.md`.

P3 is **scripted motion, not sorting.** Logical sprites move; the already
qualified P0–P2 builder and executor are unchanged in shape. P4 owns dynamic Y
ordering.

## The order, which is the whole point

```
motionTick        moves logical X/Y          main thread
buildSchedule     builds NEXT from those MOVED values
publishSchedule   one byte
frame IRQ         adopts CURRENT
executor          consumes CURRENT only
VIC
```

Nothing mutates a schedule after publication, the executor never reads logical
or motion state, and moving sprites are put through **the same** `i-6` reuse-gap
test as static ones. That last point is not cosmetic: P2 proved the gap rule is
what guarantees a merged batch's reuse window is free of sprite DMA, so
bypassing it for moving sprites would quietly remove the guarantee the whole
timing budget rests on.

`rebuild` (select a fixture: load, build, publish) and `republish` (prepare the
next frame: build, publish) are **separate entry points**. The first version of
the main loop called `rebuild` every frame, which reloaded the fixture and reset
every position immediately after motion had advanced them — the sprites sat
still, `motionFrame` read 0 forever, and the wasted work cost enough main-thread
time to start skipping scroll publications.

## One motion primitive

Every trajectory is a bounded ping-pong, per axis:

```
pos += vel
if pos >= max:  pos = max;  vel = -vel
if pos <= min:  pos = min;  vel = -vel
```

`vel == 0` is a static axis, so there is no per-sprite "kind" to dispatch on.
The result is an exact integer triangle wave, which is why the harness can state
the expected position for frame N in closed form instead of comparing the engine
against itself. Reversing on `>=` rather than `>` is what makes each endpoint
appear once (`32 33 34 33 32 31`) instead of twice.

The arithmetic is plain 8-bit (Y) and 16-bit (X) with no overflow handling. That
is a **precondition, enforced at assembly time** by the `p3s` macro: a bound
within one velocity step of 0 or of the axis maximum refuses to build. Carrying
an unreachable runtime guard instead is exactly the "unreachable-in-theory path"
this repository's own inventory blames for hiding real failures.

## Admission is stateless, and deliberately so

Admission is a pure function of the **current frame's** geometry. There is no
hysteresis. A sprite whose reuse gap oscillates across `MIN_REUSE_GAP` is
admitted and rejected on alternate frames, and therefore appears and disappears:

```
gap  31  32  33  34  33  32  31  ...
      R   R   A   A   A   R   R
```

That is the correct schedule result, not a renderer bug, and `GAP33`
(fixture 20) exists to make it observable rather than to hide it. P3
deliberately exposes and documents the behaviour **before** any policy is
invented around it. Three distinct outcomes must never be conflated:

| what you see | what it is |
|---|---|
| sprite absent while the diagnostic says rejected | correct |
| sprite absent while the diagnostic says admitted | **renderer failure** |
| sprite present while the diagnostic says rejected | **stale sprite: failure** |

## X-MSB is fully qualified here

P0–P2 were entirely X < 256, so the builder's `$D010` pass only ever cleared
bits and the accumulate-forwards structure carried a value that was always zero.
P3 made it real: each entry now **sets** its slot's bit when X >= 256 and
**clears** it when X < 256, so a reused slot is rewritten from its new owner and
a stale bit from the previous logical owner cannot survive.

* `MSBFLIP6` (17) — six leaders and six reusers on the same six slots, every
  slot's MSB inverted on reuse. The two batches' complete `$D010` values are
  exact complements on the mux bits: `$a8` then `$54`.
* `X255` (18) — sprites crossing 255↔256 in both directions while moving, on
  slots that are later reused by a sprite with the fixed opposite MSB.

## Schedule capacity is a reported fault

`MAX_LOGICAL` is 32 and `MAX_SCHED` is 24, so the cap can actually be exceeded
and the fault path can be tested. `MAX_SCHED` was **not** raised to avoid it.
Capacity is checked **before** the reuse rule, so a sprite there was no room for
is never also described as "rejected for spacing"; the scan continues, so
`statOverflow` reports how many were dropped rather than merely that some were.

## What P3 does not do

No sorter. P3 fixtures move Y only in ways that cannot reorder — rigid group
translation, or bands that cannot overlap — and `p3_model.audit()` asserts Y
order held on every frame of every fixture. Trajectories that would cross in Y
are **P4's problem and are deliberately not "fixed" here**. X may move freely,
including across 255/256, because X does not affect Y ordering; P3 uses that
freedom heavily.

## Fixtures

| # | name | what it pins down |
|---|---|---|
| 16 | `MOVE6` | baseline motion, ≤6 sprites, no slot reused |
| 17 | `MSBFLIP6` | six-slot reuse with every `$D010` bit inverted |
| 18 | `X255` | moving crossings of 255↔256, both directions |
| 19 | `YMOVE` | legal moving-Y reuse; the batch raster moves with it |
| 20 | `GAP33` | one-raster-per-frame crossing of the admission threshold |
| 21 | `SHAPE` | one admission reshapes batch count, width, slots and `$D010` |
| 22 | `MAXCAP` | exactly `MAX_SCHED`, and explicit overflow |
| 23 | `MOTION12` | integrated visual fixture: everything moving, six slots reused |

The fixture records in `src/p3_fixtures.asm` are **generated** from
`tests/p3_model.py` by `tools/gen_p3_fixtures.py`, and `make test-p3` fails if
they drift apart. The inputs have one source of truth; the expected *outputs* —
acceptance, rejection reason, slot, predecessor, gap, batch membership, complete
`$D010` — are still derived independently from the documented rules by
`tests/p2_model.py`.
