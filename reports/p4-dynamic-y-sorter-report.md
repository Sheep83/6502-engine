# P4 — dynamic Y-sorter qualification report

**Checkpoint: P4 — a deterministic dynamic Y sorter between moved logical state
and the qualified P0–P3 schedule builder.**

Status: **automated evidence GREEN. Manual visual acceptance NOT YET PERFORMED**
— see §22. Under this repository's own rules a checkpoint is not GREEN until a
human has watched a non-warp run, and that has not happened for P4.

---

## 0. Summary

Logical sprites can now cross in Y and change order every frame, and the
already-qualified renderer is unchanged in shape. Identity survives: a sprite
moves between sorted positions, accepted indices and hardware slots without
becoming a different sprite.

| | |
|---|---|
| sorter | **persistent insertion sort**, comparator `(Y, logical ID)` |
| output determinism | **proved** — same result from identity, reversed, rotated and pairwise-swapped starting arrangements |
| executor critical path vs P2/P3 | **identical at every batch size, delta +0** |
| identity through a crossing | **proved** — each sprite visits both slots, no swap |
| predecessor identity change | **proved** — entry 6's `i-6` predecessor alternates between logical ID 0 and ID 1 |
| admission changed by *another* sprite's crossing | **proved** |
| equal-Y tie → six-entry merged batch | **proved**, slots 2–7 in ID order |
| `MAX_SCHED` under reordering | **proved** — 24 accepted, overflow 2, deterministic |
| sorter cost | **~7% of main-thread preparation** |
| renderer failures | **0** |

**Two capability limits were measured for the first time, and neither is the
sorter's fault.** They are the most useful output of this checkpoint:

1. **Batch density.** The builder constrains how close two sprites *sharing a
   slot* may be, and says nothing about how close two consecutive mid-screen
   *batches* may be. Geometry that armed batches 3 rasters apart made the
   executor chain them inside one interrupt — 17 sprite writes in one
   invocation, 1078 cycles, and a frame IRQ eventually serviced at raster 194
   instead of 250. **Documented, not fixed**; admission policy was not changed
   to hide it.
2. **Main-thread ceiling.** 26 logical sprites re-sorted and rebuilt every frame
   exceeds the budget, even at the cheapest possible batch layout. P4 is the
   first checkpoint to rebuild that many per frame — P3's 30-sprite `MAXCAP` was
   static and built once. Twelve moving, crossing sprites are comfortable:
   20,000+ frames clean.

---

## 1. Files changed

| file | change |
|---|---|
| `src/sorter.asm` | **new** — `sortedIDs`/`sortedCount`, `sortWork`, `sortFault`, `sortTick`, `sortReset` |
| `src/p4_fixtures.asm` | **new, generated** — the seven P4 fixture record tables |
| `tools/gen_p4_fixtures.py` | **new** — emits the above from `tests/p4_model.py`; `--check` fails on drift |
| `tests/p4_model.py` | **new** — comparator, fixtures, per-frame audit |
| `tests/test_p4.py` | **new** — the P4 suite |
| `src/renderer.asm` | builder scans **sorted positions** (`bs_pos` → `bs_id`) instead of storage order; `schedId` records each entry's logical sprite; enable mask and `$D010` folded into the acceptance pass (§18) |
| `src/fixtures.asm` | `FIXTURE_COUNT` 24→31; P4 dispatch; `sortReset` on load; motion loader now walks records with a **16-bit pointer** (was capped at 23 sprites) |
| `src/main.asm` | `sortTick` in `republish`; `SRT`/`FLT` added to the existing P3 HUD row; `S` key |
| `src/scroll.asm` | `ROWS_PER_TICK` unchanged at 5 — tried at 4, measured, reverted (§17) |
| `tests/p2_model.py` | `build()` takes an explicit scan `order`; records `id` and `pred_id`; `sorted_order()` comparator |
| `tests/test_p0.py` | **verified** fixture selection; `Vice` now refuses to attach to a port it does not own |
| `tests/test_p1.py` | unchanged — the HUD row count stayed at five |
| `tests/test_p2.py` | `poke_logical` resets the permutation and goes through `republish` |
| `tests/test_p3.py` | stress run on its own emulator; fault counters baselined |
| `Makefile`, `README.md`, `docs/qualification-ladder.md`, `docs/manual-acceptance.md` | updated |
| `docs/p4-dynamic-y-sorter.md` | **new** |

---

## 2. Sorter alternatives considered

| candidate | assessment |
|---|---|
| **distribution / bucket over the 256 Y values** (Armalyte-style) | Rejected. Pays a fixed clear-and-walk cost **every frame regardless of how little moved** — O(range), not O(N). After P3 the main thread is the scarce resource, and a multi-thousand-cycle floor is the wrong shape for a list that is usually already correct. It is the right choice when N is large relative to the range; here N ≤ 32 against a range of 256. |
| **selection sort** | Rejected. O(N²) always: ~325 comparisons every frame for 26 sprites, to discover that nothing moved. Predictable, and predictably wasteful. |
| **persistent insertion sort** | **Chosen.** O(N + inversions). Sprites move a few rasters per frame, so the incoming list is the answer or within a couple of adjacent swaps of it — one comparison per element and no shifts at all. |

The measured shift counts justify the choice: on the crossing fixtures
`sortWork` is **0** for most frames and small single digits when sprites
actually swap.

The price is an O(N²) worst case when the incoming order is far from correct,
which happens on exactly one event: loading a fixture whose logical storage
order is deliberately scrambled. That is measured (§16), not assumed away.

---

## 3. Chosen algorithm and rationale

**Persistent insertion sort, comparator `(Y ascending, logical ID ascending)`.**

The decisive property is that **the comparator is a TOTAL order**. Logical IDs
are unique, so no two elements ever compare equal, so the set has exactly **one**
ascending arrangement. A persistent sort therefore converges to that unique
answer no matter what arrangement it started from: **persistence affects how much
work is done, never the result.**

That is what makes "persistent" safe rather than a source of history-dependence,
and it is tested directly rather than argued (§14).

---

## 4. Memory and layout

```
$1e00-$1e95  sorter (code)
$c3b0-$c3d6  sorter state: sortedIDs[32], sortedCount, sortWork, sortFault, locals
$c000-$c278  schedule buffers, now including schedId[2 x 24]
$cb00-$ce90  p4 fixture data
$ca00-$ca7b  fixture dispatch tables (moved out of the $1800 code segment,
             which ran out of room)
```

Logical arrays are **never physically reordered**. They stay keyed by logical ID;
`sortedIDs` is a permutation laid over the top.

---

## 5. Comparator and equal-Y rule

```
a before b  <=>  logY[a] < logY[b]
            or  (logY[a] == logY[b] and a < b)
```

Ties are broken by **ascending logical ID**. This is not decoration: without it,
equal-Y sprites would compare equal, the order would be partial, and the output
would depend on the incoming arrangement — i.e. on last frame's accident. P2's
merged batches *are* groups of equal-Y sprites, so that would have been a real
bug. Tie behaviour is tested at sizes 2, 3, 6 and 8 (all-equal).

---

## 6. Logical ID vs sorted index vs accepted index

| | |
|---|---|
| **logical sprite ID** | stable for the life of a fixture; indexes `logY`/`logX`/`logPtr`/`logCol` |
| **sorted position** | where that sprite currently sits in Y order |
| **accepted index** | its schedule position, which sets its physical slot (`2 + accepted mod 6`) and its same-slot predecessor (`accepted - 6`) |

`schedId` records which logical sprite each accepted entry is, so a test can ask
"which sprite is entry *i*'s predecessor" and get an **identity** back rather
than an array offset. Every P4 expectation is stated in logical IDs.

---

## 7. Static scrambled-order proof — `SORTSTATIC`

```
storage:  ID  0   1   2   3   4   5   6   7   8   9  10  11
Y:           98  61  98  60  98  64  98  62  98  63  98  65
engine sortedIDs: [3, 1, 7, 9, 5, 11, 0, 2, 4, 6, 8, 10]
model  sortedIDs: [3, 1, 7, 9, 5, 11, 0, 2, 4, 6, 8, 10]
```

Alternating high/low storage **and** a six-way equal-Y tie in one fixture. The
Y values resolve to P2's six-entry merged geometry, so if the builder had scanned
storage order the very first reuse test would have compared against the wrong
predecessor. It produces P2's six-entry merged batch from scrambled input.

Arbitrary orders driven straight into `sortTick` (§14) cover ascending,
descending, alternating high/low, a deterministic permutation, 2/3/6/8-way ties,
and a reversed 12-sprite list.

---

## 8. Adjacent crossing proof — `CROSS2`

Two sprites, each with its own numeral and colour, pass through an exact tie.

| | |
|---|---|
| sorted orders seen | exactly two, `[0,1]` and `[1,0]` |
| at the tie | ID 0 sorts first, as the tie rule requires |
| hardware slots visited | **id 0: {2,3}, id 1: {2,3}** |

Each sprite occupies **both** hardware slots over the crossing — it is
reprogrammed onto the slot the other one was using — without changing identity.
That is the property the whole checkpoint exists to establish, and it is the one
a human checks by watching the numerals rather than the positions.

---

## 9. Multi-crossing proof — `CROSS6`

Six sprites interleave continuously (even IDs sweep down, odd IDs sweep up) over
six static reusers on the same six slots.

| | |
|---|---|
| distinct sorted orders over 120 frames | **≥ 6** |
| crossing sprites that visit more than one slot | **all six** |
| accepted count | 12 on every frame |
| frames verified against the model | 40 consecutive, field by field |

Because the six reusers below never move, every change in *their* same-slot
predecessor is caused purely by the crossings above.

---

## 10. Predecessor-change proof — `PREDCHANGE`

IDs 0 and 1 swap around Y 61 while everything else stands still. The reuser
(ID 6) never moves at all.

| frame | Y(id0) | Y(id1) | sorted head | entry 6 predecessor | gap |
|---:|---:|---:|---|---|---:|
| 0 | 60 | 62 | `[0,1,…]` | **id 0** | 38 |
| 1 | 61 | 61 | `[0,1,…]` (tie) | **id 0** | 37 |
| 2 | 62 | 60 | `[1,0,…]` | **id 1** | 38 |

The same-slot predecessor changes **identity**, and the gap is then recomputed
against the new one. Both states are comfortably legal, so admission does not
change — this fixture isolates predecessor identity from admission, which
`SORTSHAPE` then varies deliberately. Recorded as logical IDs in both the model
and the engine (`schedId`), never inferred from counts.

---

## 11. Admission-churn proof — `SORTSHAPE`

ID 5 sweeps down past five static leaders, so accepted entry 0 alternates between
ID 5 and ID 0. The reuser ID 6 **sits at a fixed Y and never moves** — but its
gap against entry 0 is 34, 33, 32 or 31 depending on *who entry 0 currently is*.

| Y(id5) | entry 0 | gap for id6 | id6 | accepted | batches | `$D010` |
|---:|---|---:|---|---:|---:|---|
| 60 | id 5 | 34 | **IN** | 12 | 3 | changes |
| 63 | id 0 | 31 | **out** | 11 | 2 | changes |

A sprite is admitted or rejected **by somebody else's movement**. That admission
change then reshapes everything below it: IDs 7–11 shift by one accepted index,
onto different physical slots, changing the complete `$D010`.

No hysteresis was added. Admission remains a deterministic function of this
frame's sorted, moved geometry, and the consequence is made observable rather
than hidden.

---

## 12. Equal-Y merged-batch proof — `TIE6`

```
storage:  IDs 0..5 at Y 98      IDs 6..11 at Y 60..65
sorted:   [6, 7, 8, 9, 10, 11, 0, 1, 2, 3, 4, 5]
```

A complete block swap. The six-way tie resolves by ascending logical ID onto
**hardware slots 2–7 in that order**, producing P2's six-entry merged batch with
the complete `$D010` the model predicts, at P2's cost (§19).

---

## 13. `MAX_SCHED` under dynamic ordering — `SORTCAP`

26 logical sprites: four six-way ties (24 accepted, four batches — the least a
24-sprite schedule can cost) plus a crossing pair below the display that cannot
fit.

| | |
|---|---|
| accepted | **always exactly 24** |
| overflow | **always exactly 2** |
| accepted set is the first `MAX_SCHED` in sorted order | every frame |
| distinct sorted orders | **> 1** — the order changes every other frame |
| distinct accepted-ID lists | **1** — reordering does **not** make overflow nondeterministic |
| memory safety | an overflowing build never writes outside its own buffer (sentinel in the other buffer survives) |

The shape took three attempts, and the discarded ones are the findings:

- **30 sprites at pitch 7, ±4** → consecutive batches 3 rasters apart → the
  executor chained them (17 writes in one invocation, 1078 cycles, frame IRQ at
  raster 194). **Batch-density limit** — §20.
- **13 crossing pairs in 8-raster bands** → spacing fixed, but nineteen
  mid-screen batches, and still late.
- **Four ties + a crossing pair** → four batches, `statLate` **0**. What remains
  is main-thread cost, which is the ceiling in §17.

---

## 14. Independent model results

`tests/p2_model.py` derives the expected schedule from the documented rules —
acceptance, rejection reason, slot, same-slot predecessor **identity**, reuse
gap, batch raster, batch membership, complete `$D010`, overflow — with no
knowledge of what the 6502 produced. `tests/p4_model.py` adds the comparator and
a per-frame audit (permutation, ascending Y, tie rule, gap legality).

Compared per frame against the running machine on every fixture. The output
contract is checked **exhaustively**, not sampled: permutation (no duplicate, no
missing ID), ascending in Y, every tie broken by ascending ID.

**Determinism, tested directly.** `sortedIDs` was overwritten behind the engine's
back with four different starting arrangements and `sortTick` called in
isolation:

```
from identity    -> [3, 1, 7, 9, 5, 11, 0, 2, 4, 6, 8, 10]
from reversed    -> [3, 1, 7, 9, 5, 11, 0, 2, 4, 6, 8, 10]
from rotated     -> [3, 1, 7, 9, 5, 11, 0, 2, 4, 6, 8, 10]
from swap-pairs  -> [3, 1, 7, 9, 5, 11, 0, 2, 4, 6, 8, 10]
```

Identical every time — the order is a function of the input state alone.

Arbitrary Y sets driven straight into `sortTick`: ascending, descending,
alternating high/low, deterministic permutation, two equal, three equal, six
equal, **all equal** (ordered purely by ascending ID), and a reversed 12-sprite
list. All matched the model.

On the one place the model is not independent, stated plainly: the fixture
*inputs* have a single source of truth in `p4_model.py` and `src/p4_fixtures.asm`
is generated from it, exactly as P3 does. That removes transcription error in
~130 records; it does not weaken the independence of the expected **outputs**.
`make test-p4` fails if the generated file drifts.

---

## 15. Sorter integrity diagnostics

`sortTick` only ever **moves** entries already in the array, so it cannot invent
or lose an ID, and it terminates ordered by construction. Duplicates, missing IDs
and out-of-order pairs are therefore structural impossibilities absent memory
corruption — and paying O(N) every frame to re-check them would spend the scarce
resource on reassurance.

So the division is deliberate:

| check | where | cost |
|---|---|---|
| `sortedCount == logCount` | engine, sets saturating `sortFault` | free |
| `sortWork` (shift count) | engine | ~5 cycles per shift |
| permutation / ordering / tie rule | **harness**, reading `sortedIDs` | zero to the engine |

On screen: the P3 row shows `SRT` (sorted count) and `FLT` (sorter fault)
alongside `MOV`, `MFRM` and `OVF`. `sortWork` is a timing diagnostic the tests
read directly rather than something a human watches, and giving the sorter a
HUD row of its own turned out to cost real main-thread time — see §17.

---

## 16. Sorter timing

Span measured from `sortTick` entry to `buildSchedule` entry. **The span includes
the raster IRQs that interrupt it**, so on a batch-heavy fixture it measures
elapsed time rather than sorter work; `sortWork` is IRQ-independent and is shown
alongside.

| fixture | sprites | sort min / median / max | `sortWork` |
|---|---:|---|---:|
| `CROSS2` | 2 | 134 / 134 / 169 | 0 |
| `PREDCHANGE` | 7 | 489 / 519 / 524 | 0–1 |
| `CROSS6` | 12 | 884 / 884 / 1021 | 0 |
| `SORTSTATIC` | 12 | 884 / 884 / 884 | 0 |
| `TIE6` | 12 | 884 / 884 / 884 | 0 |
| `SORTCAP` | 26 | 1838 / 2749 / 9640 | 0–13 |

The steady state is the already-sorted case — one comparison per element and no
shifts — which is exactly what the algorithm was chosen for. The worst case is
the scrambled load, and it is a one-off per fixture selection.

**The sorter is ~7% of main-thread preparation** (1021 of 15277 on `CROSS6`).

---

## 17. Whole main-thread preparation timing

Span from `motionTick` entry to `scrollPublish` entry, again including IRQs.

| fixture | sprites | sorter min/med/max | worst prep | of 19,656 | skips |
|---|---:|---|---:|---:|---:|
| `CROSS2` | 2 | 134 / 134 / 169 | 7,518 | 38.2% | **0** |
| `PREDCHANGE` | 7 | 489 / 519 / 524 | 10,391 | 52.9% | **0** |
| `SORTSTATIC` | 12 | 884 / 884 / 884 | 13,421 | 68.3% | **0** |
| `TIE6` | 12 | 884 / 884 / 884 | 13,422 | 68.3% | **0** |
| `CROSS6` | 12 | 884 / 884 / 1021 | 13,861 | 70.5% | **0** |
| **`SORTCAP`** | **26** | 1998 / 2260 / 4361 | **16,788** | **85.4%** | **39 — the ceiling** |

Component breakdown for `CROSS6` (worst frame of each segment), after the
builder fold described below:

```
motion   635      sort  1021      build  ~4600     publish  87      regen  8701
```

**`regenTick` dominates, not the sorter.** Back-page regeneration is the largest
single term; the sorter is 1,021 cycles of it — about 7%.

For scale: `CROSS6` — twelve sprites, six of them continuously crossing, over the
scrolling playfield — now sits at **70.5%** of a PAL frame with zero publication
skips over 20,000-frame runs. P3's heaviest fixture, `MOTION12`, sits at 77.6%
and is likewise clean.

### The regression P4 caused, and paid back

Adding the sorter cost ~900 cycles a frame, plus ~200 for the builder's extra
indirection. On a system whose heaviest fixture already sat at ~68% of a PAL
frame, that was enough to matter: **P3's `MOTION12` began missing publications.**

It was confirmed as a genuine P4 regression by A/B test, not assumed — the same
probe, on the same machine, against the pre-P4 binary from `git stash`:

| binary | `MOTION12`, ~20,000 frames each | publication skips |
|---|---|---|
| pre-P4 | two runs | **0, 0** |
| P4, before the fix | four runs | 0, 38, 42, 200 |
| **P4, after the fix** | **four runs** | **0, 0, 0, 0** |

Two levers were tried and **measured not to work**, and both were reverted
rather than kept on the assumption that they must have helped:

- **`ROWS_PER_TICK` 5 → 4.** The worst preparation span barely moved
  (17,178 → 17,392) and not one skip disappeared. The cost that matters is the
  worst frame, not the average, and spreading regeneration does not change which
  frame is worst. The scroller was requalified during the attempt (P1 green,
  `scrollLate` 0 over 19,369 frames) and then restored to 5.
- **A sixth diagnostic HUD row.** Round robin made it free per *frame*, but every
  HUD row must also be stamped into the back page as it regenerates. Removing it
  dropped regeneration's worst frame but left the total unchanged. The sorter's
  diagnostics were folded onto the existing P3 row instead — which is where they
  belong anyway.

**What did work was giving the cycles back where they were being wasted.** The
builder made three passes over the accepted entries: acceptance, then a full walk
to build the `$D015` enable mask, then another full walk to accumulate `$D010`.
Every value those walks needed — the slot and the X MSB — is already in hand
during acceptance. Folding both in, and recording the running `$D010` per entry
so a batch's value is a single lookup rather than a re-accumulation:

| `buildSchedule` phase, 12 sprites | before | after |
|---|---:|---:|
| acceptance | 2,532 | 3,359 |
| enable mask | 659 | **17** |
| batch | 901 | 900 |
| max-batch | 109 | 98 |
| `$D010` | 1,058 | **150** |
| **total (median)** | **5,243** | **4,510** |

`MOTION12`'s worst preparation span fell from **17,222 (87.6%)** to **15,261
(77.6%)** — the same level as `CROSS6`, which has been clean in every run — and
the skips went away and stayed away.

This is the one place P4 modified qualified P0–P3 machinery, and it was done on
measurement rather than instinct: the phase breakdown named the two passes, both
outputs are compared field by field against independent models in all five
suites, and the full regression is green.

### The measured ceiling

`SORTCAP` — 26 logical sprites re-sorted and rebuilt every frame — **exceeds the
main-thread budget** and records publication skips even at the cheapest possible
batch layout (four batches, `statLate` 0). This is an engine capability ceiling
P4 is the first checkpoint to reach: P3's 30-sprite `MAXCAP` was *static* and
built once, so it only ever paid the IRQ cost.

**Twelve moving, crossing sprites are comfortable** — `CROSS6` runs 20,000+
frames clean at ~78%. That is the number the rotating-ring checkpoint should be
planned against, and it is why a 16-sprite ring is a sensible target and a
24-sprite one is not.

### `ROWS_PER_TICK`: applied, then reverted

P3 identified back-page regeneration as available headroom (25 rows over 8
frames needs 3.125, so four a frame would do) and said not to spend it without
evidence. P4 appeared to have evidence, applied four rows, and **requalified the
scroller completely** (P1 green, `scrollLate` 0 over 19,369 frames).

Then the evidence dissolved, twice:

- most of the skips were the **test harness**, not the engine — hijacking the PC
  mid-frame to select a fixture costs a skip or two, and those accumulate in
  saturating counters shared by every fixture measured in the same emulator. On
  a fresh machine, left to settle and run, `CROSS6` is clean at **five** rows
  over 20,123 frames;
- the one fixture that really did fault, `SORTCAP`, **faulted at four rows too**
  (62 skips in 19,601 frames), because its problem is main-thread cost, not
  regeneration.

So the lever was **reverted to 5**. The headroom is real and still available;
P4 has no measurement that needs it, and a qualified scroller is not worth
changing on evidence that turned out to be of the harness. The reasoning is
recorded in `src/scroll.asm` next to the constant.

---

## 18. Publication skips

Zero on every fixture within the measured budget, over 20,000-frame runs on
dedicated emulators:

| fixture | frames | `publishSkip` | `statLate` | `scrollLate` |
|---|---:|---:|---:|---:|
| `CROSS6` (P4 integrated) | 20,670 | **0** | **0** | **0** |
| `MOTION12` (P3 integrated) | 20,779 / 20,823 / 20,585 / 20,601 | **0 every run** | **0** | **0** |
| `SORTCAP` | 19,650 | 136 — **the ceiling, §17** | 0 | 0 |

`MOTION12` is shown four times deliberately: before the builder fix it was
intermittent (0, 38, 42, 200 across four runs), so a single clean run would not
have been evidence of anything.

Harness lesson, now fixed in both suites: fault counters are cumulative and
saturating, so an endurance run that shares an emulator with a dozen fixture
selections reads their transients as its own. Endurance runs now get their own
emulator, settle first, and compare **deltas** while printing the baseline so
contamination is visible rather than silently subtracted.

---

## 19. Executor timing vs P2/P3

Same phase (P2's worst, 7), same static fixtures, same geometry.

| batch entries | P2 baseline | P4 measured | delta |
|---:|---:|---:|---:|
| 1 | 212 | **212** | **+0** |
| 2 | 291 | **291** | **+0** |
| 3 | 366 | **366** | **+0** |
| 4 | 447 | **447** | **+0** |
| 5 | 520 | **520** | **+0** |
| 6 | 646 | **646** | **+0** |

**No P4 code entered the executor.** Asserted at source level too: the raster
handler references none of `sortTick`, `sortedIDs`, `sortedCount`, `sortWork`,
`logY`, `logX`, `sortReset`.

Sorting fixtures under natural scrolling: `SORTSTATIC` 640, `CROSS6` 646, `TIE6`
640 — all six-entry batches, all within the 756-cycle deadline and the stricter
693-cycle fetch deadline. **A sorted six-entry batch costs exactly what P2's
static one did.**

---

## 20. A limit found and deliberately not fixed

The builder constrains how close two sprites **sharing a slot** may be
(`MIN_REUSE_GAP`). It has **no rule about how close two consecutive mid-screen
batches may be.** Every fixture through P3 was sparse enough that this never
mattered.

Reproduction: 30 sprites at uniform pitch 7, each ping-ponging ±4 (`ylo = base-4`,
`yhi = base+4`, alternating velocity sign), which puts consecutive accepted
sprites as little as **3 rasters** apart while a single-entry batch takes about 5
rasters to execute. Observed:

- the executor's late-recovery path chains batch after batch inside one
  interrupt — **17 sprite writes in a single handler invocation, 1078 cycles**;
- `statLate` non-zero and rising;
- a frame IRQ eventually serviced at **raster 194 instead of 250**.

This is a **builder admission gap, not a sorter fault**, and P4 did not change
admission policy to paper over it — the brief is explicit that an inappropriate
capacity/admission semantic should be documented rather than silently altered.
It is the first thing the next checkpoint should decide: either a minimum batch
separation in the builder, or an explicit statement that geometry this dense is
the caller's responsibility.

---

## 20b. Full regression

All five suites, run in sequence against the final binary:

| suite | checks passed | failures |
|---|---:|---:|
| `test_p0.py` | 90 | **0** |
| `test_p1.py` | 59 | **0** |
| `test_p2.py` | 117 | **0** |
| `test_p3.py` | 87 | **0** |
| `test_p4.py` | 94 | **0** |
| **total** | **447** | **0** |

P3's integrated run reports `fault counters BEFORE this run: all zero` and
`caused by this run: ... publish-skip 0`, which is the regression in §17 closed.

Executor critical path, re-measured on the final binary — **unchanged from P2 at
every batch size**:

| entries | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---:|---:|---:|---:|---:|---:|
| P2 baseline | 212 | 291 | 366 | 447 | 520 | 646 |
| P4 measured | 212 | 291 | 366 | 447 | 520 | 646 |
| delta | +0 | +0 | +0 | +0 | +0 | +0 |

Sorting fixtures under natural scrolling all hit six-entry batches within both
deadlines: `SORTSTATIC` 640, `CROSS6` 646, `TIE6` 640, `SORTCAP` 646 — against
756 (display) and 693 (fetch).

---

## 21. Scrolling / page / pointer / fine-phase coverage

`CROSS6` over the scrolling playfield, ~20,000 frames:

- all eight fine-scroll phases exercised while sorting;
- both screen matrices displayed, coarse step and page flip every eight frames;
- `$d018`/software-page mismatch **0**;
- pointer-destination mismatch **0**;
- late recoveries **0**, back-page-late **0**, publication skips **0**;
- sorter faults **0**, overflow **0**;
- every page flip at raster 250 (`flipLineMin == flipLineMax == 250`).

CURRENT immutability under sorting: with the main thread parked on a
jump-to-self, frames keep rendering while CURRENT's **logical IDs** and Y values
are byte-identical before and after, and the sorted order stops changing.

---

## 22. Manual acceptance procedure

**Not yet performed. This is what remains before P4 can be called GREEN.**

```sh
make run
```

Press **S** to jump to the first P4 fixture (24), then SPACE to advance. Row 20
shows `SRT` (sorted count) and `FLT` (sorter fault).

- **`CROSS2` (25)** — the identity check. Two sprites pass through each other;
  **watch the numerals, not the positions**. Each changes hardware slot as they
  cross. Fail on an identity swap, a disappearance at the crossing, a teleport,
  a duplicate, or a sprite left behind.
- **`CROSS6` (26)** — leave running several minutes. The strongest human check
  before the ring: six sprites interleaving while six more are reused on the
  same slots.
- **`SORTSHAPE` (28)** — expected blinking. One sprite appears and disappears
  because *another* sprite crossed ahead of it. Judge it by `ACC` on row 1: a
  mismatch between the count and what is visible is a failure; the blinking is
  not.
- **`SORTCAP` (30)** — the ceiling fixture. Deliberately past budget and expected
  to stutter the scroll occasionally; the sprites themselves must still be
  correct.

Fail conditions specific to P4: `FLT` ever non-zero; `SRT` not equal to `LOG`;
two sprites exchanging numeral or colour as they cross; a sprite vanishing
exactly when it changes slot.

Human visual observation remains authoritative. This suite runs headless and
cannot see an identity swap.

---

## 23. VICE process hygiene

`pgrep -fl x64sc` before the suites: **none running**. Every launch is owned by
PID, terminated and reaped in `try/finally`, and verified gone; other `x64sc`
processes are reported and never touched; no broad `pkill`; no `open -a`; all
automated launches use `-console`, so no window is created and no keyboard focus
is taken. `make run` remains windowed.

**Two hygiene faults found and fixed**, both of which produced wrong results
before they produced obvious symptoms:

1. **A shadowed variable defeated the reap.** `v = verify_order(...)` overwrote
   the `Vice` handle with a list, so `finally: v.close()` raised
   `AttributeError` and the emulator survived the suite. The **next** run then
   attached to it and measured a machine in the previous run's state — the logY
   it read belonged to a fixture that run had never selected. Fixed, and
   prevented structurally: `Vice` now refuses to start on a port somebody else
   is serving, and verifies after launch that the port is served by **the PID it
   launched**.
2. **Trace logs** keep P3's discipline: one unique path per attempt, never
   unlinked while its VICE still owns it, swept only after the process is
   reaped. P4 has its own `sweep_logs()` for its own scratch directory.

---

## 24. Disk usage

```
build/                 68K   (engine.prg, main.sym, main.vs)
repo excluding .git   972K
```

Fixed build outputs, no per-run directories; scratch under
`/tmp/6502-engine-p4`, asserted empty before the suite exits. The generated
fixture file is not rebuilt by `make build` — a build must never silently
rewrite source; `make p4-fixtures` regenerates it and `make test-p4` fails on
drift.

---

## 25. Failures and smallest deterministic fixtures

**No renderer failure occurred.** The sorter, the builder and the executor were
correct throughout; nothing produced a wrong sprite, a lost identity or a stale
entry.

Preserved deterministic reproducers for the two capability limits:

| finding | reproduction |
|---|---|
| **batch density** (§20) | 30 sprites, uniform pitch 7, each `yvel ±1` with `ylo = base-4`, `yhi = base+4`, alternating sign. Recorded in `p4_model._sortcap()`'s docstring. |
| **main-thread ceiling** (§17) | `SORTCAP` as shipped — 26 sprites, four merged ties plus a crossing pair — at four batches. |

Defects found and fixed during P4, none in the pre-existing engine:

1. `poke_logical` (P2 harness) wrote `logY` but not the sorted order, so the
   builder walked a stale permutation naming IDs that no longer existed —
   presenting as sprites out of Y order rejected as "physically unsafe".
2. Isolated routine calls left the PC at the RTS sentinel instead of restoring
   `mainLoop`, derailing the machine so every later fixture selection failed.
3. The shadowed `Vice` handle described in §23.
4. A memory-safety check that treated the byte after a buffer's 24 entries as
   spare space; it is entry 0 of the **other** buffer, legitimately overwritten.
5. P0's fixture selection was never verified; it silently built the previous
   fixture once. Now verified and retried.

---

## 26. Recommendation for the rotating-ring checkpoint

P4's automated evidence is clean and the sorter is independently qualified, so
the next checkpoint can add the integrated ring — with four things carried
forward:

1. **Size the ring against the measured ceiling, not against `MAX_SCHED`.**
   Twelve moving, crossing sprites cost ~78% of a frame. Sixteen is a plausible
   target; twenty-four is not, and `SORTCAP` is the evidence. Budget the ring at
   16 and measure before adding anything else.

2. **Decide the batch-density rule first** (§20). A ring spanning most of the
   playfield will put sprites at arbitrary vertical separations, including a few
   rasters apart — exactly the geometry that made the executor chain batches.
   This is the one outstanding correctness question and it belongs *before* the
   ring, not during it.

3. **`regenTick` is where the remaining headroom is, not the sorter.** Back-page
   regeneration is the largest main-thread term; the sorter is ~7%. But note
   what P4 learned the hard way: `ROWS_PER_TICK` is **not** the lever — it was
   tried, measured, and reverted, because it changes the average and not the
   worst frame. If the ring needs room, look at what the worst frame actually
   does. The builder still makes a separate pass for batch construction that
   could plausibly fold into acceptance the same way the enable mask and `$D010`
   just did, and `renderRow` redraws forty columns per row unconditionally.

4. **Keep the deterministic crossing fixtures.** `CROSS2` and `CROSS6` isolate
   identity and ordering from everything else. When the ring misbehaves, the
   question "is the sorter wrong or is the integration wrong" is answered by
   re-running them — which is the whole reason P4 was kept separate from the
   ring.

Also: keep `-console` for automated suites and manual acceptance windowed; and
keep endurance runs on their own emulator with baselined counters (§18).
