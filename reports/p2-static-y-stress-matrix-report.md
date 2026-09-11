# P2 — static-Y stress matrix proof report

**Checkpoint: P2 — deterministic static-Y stress matrix over the P1 scrolling
double-buffered playfield.**

Status: **automated evidence GREEN. Manual visual acceptance NOT YET PERFORMED**
— see §15. Under this repository's own rules a checkpoint is not GREEN until a
human has watched a non-warp run, and that has not happened for P2.

---

## 0. Summary

P1 left one thing unmeasured. `REUSE_LEAD = 12` was sized for a **six-entry
merged mid-screen batch**, but every mid-screen batch any P0 or P1 fixture ever
produced held exactly **one** entry. The 756-cycle budget was therefore argued,
not measured, and the ~322-cycle worst case P1 reported did not test the case the
constant exists for.

P2 built that batch, executed it, and measured it.

| | |
|---|---|
| six-entry merged mid-screen batch | **built, executed and proved two independent ways** |
| worst critical path (IRQ entry → last VIC register write) | **646 cycles** |
| budget (`REUSE_LEAD * 63`) | **756 cycles** |
| **margin** | **+110 cycles = 1.75 raster lines** |
| stricter sprite-*fetch* deadline (`11 * 63 = 693`) | also met, +47 |
| worst fine-scroll phase | **7** |
| renderer failures | **0** |
| **`REUSE_LEAD` conclusion** | **stays at 12** |

Two structural findings changed how the measurement had to be done, and both
are more useful than the headline number:

1. **A correctly scheduled merged batch never competes with sprite DMA.** The
   acceptance rule itself guarantees it. Badline theft is the only variable.
2. **Cost is a step function of badlines inside the batch's CRITICAL PATH**, not
   inside the nominal 12-line reuse window. An earlier version of this suite
   asserted the latter; the measurement refuted it and the check was rewritten.

---

## 1. Files changed

| file | change |
|---|---|
| `src/renderer.asm` | `statMaxBatch` (widest mid-screen batch, builder); `batchSizeHist` (executed mid-screen batch sizes, 16-bit × 7, executor); `ex_n0`; `exWritesDone` timing-probe label; one branch inverted for range |
| `src/scroll.asm` | `pinFine` / `pinFineValue` diagnostic phase hold; `HUD_ROW_P2` treated as a HUD row; segment moved `$1900` → `$1a00` |
| `src/fixtures.asm` | eleven P2 fixtures (5–15); `fixtureYOffset` vertical sweep; `loadFixture` X-column cursor fixed to a true mod-7; `logPtr` wrapped at `SPRITE_COUNT` |
| `src/main.asm` | `HUD_ROW_P2` (row 22): `LOG / MXB / OFF / B6 / PH / PG` |
| `tests/p2_model.py` | **new** — independent model with full provenance (predecessor, gap, rejection reason, batch membership) |
| `tests/test_p2.py` | **new** — the P2 suite |
| `tests/test_p0.py` | `-console` launch (no window, no focus theft) |
| `tests/test_p1.py` | `HUD_ROWS` now `(1, 2, 22, 23)` |
| `Makefile` | `test-p2` target; `test` runs P0+P1+P2; **path quoting** |
| `README.md`, `docs/qualification-ladder.md`, `docs/p2-static-y-matrix.md`, `docs/manual-acceptance.md` | updated |

### Two changes that were not asked for, and why

**`Makefile` path quoting.** The build did not run at all in this checkout.
`$(ROOT)` was unquoted and this repository's path contains a space
(`/Users/brianmorrice/dev/C64 ASM/6502-engine`), so KickAssembler received
`/Users/brianmorrice/Dev/C64` as its output file and failed with *"Is a
directory"*. Nothing else in P2 could proceed until this was fixed. (The task
brief named `/Volumes/SSD/dev/C64/6502-engine`, a space-free path that does not
exist on this machine; that is presumably why this had never surfaced.)

**`loadFixture` sprite-pointer overrun.** There are 16 sprite bitmaps but
`MAX_LOGICAL` is 24, and `logPtr` was `logical index + SPRITE_PTR_FIRST` with no
wrap. Fixture 14 uses all 24, so logical sprites 16–23 pointed at `$2400`–`$25ff`
— past `spriteBitmapsEnd`, into uninitialised RAM — and the last eight sprites
displayed **noise**. Found by looking at a screenshot of the fixture, not by any
counter: timing, batch membership and every coherence counter were completely
unaffected, which is a fair reminder of why manual visual acceptance outranks the
harness in this repository. Fixed by wrapping the bitmap index at `SPRITE_COUNT`,
with an assembler guard that the count stays a power of two. Numerals now repeat
above 15; within any one batch the six sprites still carry six different
numerals.

**`loadFixture` X-column derivation.** The old form was `index AND 7`, clamped
to 0 at 7 — which maps logical sprite 7 *and* logical sprite 8 to the same
column. With P0 geometry those two sprites always had different Y, so the
collision was invisible. With a P2 fixture whose six sprites **share** a Y it
would have drawn two of them exactly on top of each other, and the six-entry
merged batch would have looked like five sprites to a human performing manual
acceptance. Replaced with a true mod-7 cursor. This also makes F2's cascade
repeat cleanly and changes no test expectation.

---

## 2. P0/P1 architecture intact

Nothing structural was redesigned. Specifically preserved:

- **HW2–7 six-slot mux pool, HW0–1 reserved** — asserted per fixture.
- **`accepted - 6` same-slot reuse** — now asserted per *entry*, by checking
  that entry *i* and entry *i-6* really hold the same hardware slot in the
  built schedule, not merely that the counts agree.
- **`REUSE_LEAD = 12`** — unchanged, and now measured (§8).
- **Atomic frame publication at raster 250** — `flipLineMin == flipLineMax ==
  250` over every flip of every P2 run.
- **Immutable CURRENT schedule** — untouched. The executor still reads nothing
  but the schedule; P1's "freeze the main thread dead" test still passes.
- **One `sta $d018`, one pointer store, one writer of `exPtrStore+2`** —
  `test_p1.py`'s source-level single-writer checks still pass unmodified.
- **One active sprite-pointer destination per displayed frame** — zero
  mismatches under P2's heaviest fixtures.

The renderer additions are diagnostic counters only. The one that touches the
executor (`batchSizeHist`) is placed **after** `exWritesDone`, so it cannot
delay a single sprite register write — see §5.

---

## 3. The six-entry fixture, exactly

Geometry is **derived from the reuse rule**, not taken from the brief's
illustration:

```
accepted entry i reuses the slot of accepted entry i-6
acceptance needs   Y_i - Y_(i-6) >= MIN_REUSE_GAP (33)
all six must share one batch line  ->  all six share one Yc
the binding pair is the LAST reuser against the LAST leader:

    Yc - (Y0 + 5) >= 33     ->     Yc >= Y0 + 38
    Y0 = 60                 ->     Yc  = 98
```

**Fixture 5 (`T6`)** — `60 61 62 63 64 65 98 98 98 98 98 98`

| | |
|---|---|
| logical sprites | 12 |
| accepted | 12 |
| rejected | 0 unsafe, 0 conservative |
| leaders Y | 60 61 62 63 64 65 |
| leaders slots | 2 3 4 5 6 7 |
| reusers Y | 98 98 98 98 98 98 |
| reusers slots | 2 3 4 5 6 7 |
| predecessor Y per slot | 60 61 62 63 64 65 |
| **reuse gap per slot** | **38 37 36 35 34 33** (`MIN_REUSE_GAP` = 33) |
| batch rasters | 250 (frame), **86** (mid-screen) |
| batch membership | `(first 0, count 6)`, **`(first 6, count 6)`** |
| fine phase | all eight, pinned and natural |
| badline interaction | see §6 |

`Yc = 98` is therefore **two things at once**: the smallest Yc that merges six
entries into one batch, and the **exact conservative boundary** for the binding
pair (gap 33 = `MIN_REUSE_GAP`). One raster lower and it becomes a five-entry
batch — which is exactly what fixtures 6–10 step through.

**Fixture 14 (`T6X3`)** extends this to **three** six-entry merged batches in one
frame — 24 logical sprites, exactly `MAX_SCHED` — at rasters 86, 124 and 162.
Every one of the 18 reuse events is legal; all six slots are reprogrammed three
times per displayed frame.

---

## 4. Proof the six-entry merged batch EXECUTED

A schedule containing a six-entry batch proves nothing on its own. Two
independent proofs that the executor really ran one:

**Proof 1 — in-engine executed-size histogram.** `batchSizeHist` is written by
the executor, indexed by the batch's own entry count, mid-screen batches only:

```
executed mid-screen batches by size 0..6:  [0, 0, 0, 0, 0, 0, 8462]
```

Every mid-screen batch executed had **six** entries, and none had any other
size. Over a scrolling run the same counter reaches **20,003** for `T6` (one per
frame over 20,004 frames) and **46,683** for `T6X3` (three per frame over 15,562
frames), still with zero of any other size.

**Proof 2 — count the sprite writes inside a batch, on the machine.**
`exPtrStore` is the single instruction that writes a sprite pointer, executed
once per entry. Tracing it alongside `irqHandler` and `exWritesDone` counts the
register writes performed *inside each individual batch execution*:

```
every sampled mid-screen batch performed SIX sprite writes
entry counts seen: [6]
```

The two proofs are independent: one is a counter compiled into the engine, the
other is an emulator trace of a different instruction.

---

## 5. Timing methodology

P1's corrected harness is retained in full: free-run with tracing rather than
monitor-step loops, wait for the log to settle, assert sample counts, match
entry rasters against armed lines allowing 0–1 lines of jitter, and saturating
/ wide counters.

**Two timing points, not one.** P0 and P1 measured `irqHandler → exDone`, the
whole handler. That overstates the batch cost, and the overstatement grows every
time a diagnostic is added. P2 adds a zero-cost label, `exWritesDone`,
immediately after the last VIC register store:

| measurement | meaning |
|---|---|
| **critical path** (`irqHandler → exWritesDone`) | every Y, X, colour, pointer and `$d010` written. **This is the instant the reuse deadline applies to.** |
| whole handler (`irqHandler → exDone`) | plus bookkeeping, histogram and re-arming. Reported for continuity with P0/P1. |

All margins below are stated against the **critical path**, which is the honest
number; the whole-handler figure is given alongside.

**Two deadlines.** `REUSE_LEAD * 63 = 756` cycles is the documented budget
(reprogram before raster `Yc`). The stricter reading is `11 * 63 = 693`, because
the VIC fetches a sprite's data on the line *before* it displays. Both are
reported; both are met.

**Diagnostic cost, stated honestly.** `batchSizeHist` costs ~25 cycles and the
inverted branch ~1, both **after** the last register write. They inflate the
whole-handler figure (P1's 322 → 353 on the P0 fixture-2 baseline) and do **not**
touch the critical path. The shipped engine contains them, so the measurements
are of the real thing.

---

## 6. Timing by fine-scroll phase, and badline interaction

Fixture 5, phase pinned by `pinFine`/`pinFineValue` and **verified from `$d011`
on the running machine**, not from the poke.

`in win` = badlines in the nominal 12-line window (rasters 86–97).
`in crit` = badlines actually inside the measured critical path.

| phase | `$d011&7` | in win | in crit | samples | critical | whole handler | margin |
|---:|---:|---|---|---:|---:|---:|---:|
| 0 | 0 | 88, 96 | 88 | 288 | 603 | 731 | **+153** |
| 1 | 1 | 89, 97 | 89 | 379 | 603 | 688 | **+153** |
| 2 | 2 | 90 | 90 | 382 | 603 | 688 | **+153** |
| 3 | 3 | 91 | 91 | 353 | 603 | 688 | **+153** |
| 4 | 4 | 92 | 92 | 314 | 603 | 688 | **+153** |
| 5 | 5 | 93 | 93 | 2708 | 603 | 688 | **+153** |
| 6 | 6 | 86, 94 | 94 | 655 | 603 | 688 | **+153** |
| **7** | **7** | **87, 95** | **87, 95** | 651 | **646** | 731 | **+110** |

**Which phase/raster combinations meet badline theft.** A badline lands on any
raster in 48–247 where `(raster & 7) == YSCROLL`, costing ~40–43 cycles. Every
phase meets at least one inside the critical path. **Only phase 7 meets two**,
and it is the only phase that costs more: 646 − 603 = **43 cycles, exactly one
badline**.

**The nominal window is the wrong thing to count.** Phases 0, 1 and 6 each have
two badlines in the 12-line window and still cost the minimum:

- phases 0 and 1 — the second badline (96, 97) falls **after** the last register
  write, so it costs nothing;
- phase 6 — the badline at 86 is on the **entry line**. The CPU is already
  stalled when the raster IRQ fires, so that theft lands in interrupt latency,
  ahead of the first traced instruction, and outside the span being measured.

Excluding the entry line makes cost an **exact step function** of the in-path
badline count across all eight phases. The suite's earlier check asserted that
in-*window* count predicts cost; the measurement refuted it, and the check was
replaced by what the machine shows rather than the hypothesis being preserved.

**Why sprite DMA never appears in this analysis.** The acceptance rule forces:

```
batch fires at        Yc - 12
predecessor DMA ends  <= (Yc - 33) + 20 = Yc - 13   (one line EARLIER)
the batch's own DMA   starts at Yc - 1 = batch line + 11  (the deadline itself)
```

A correctly scheduled merged batch therefore executes in a structurally
**DMA-free** window, at every legal gap and every vertical position. Badline
theft is the only variable — which is why the phase sweep is the experiment that
matters, and why the vertical sweep changes so little.

---

## 7. Timing by merged batch size

Fixtures 10, 9, 8, 7, 6, 5 — identical leaders, **one controlled variable**:
how many sprites share the reuse raster. Pinned to the worst phase (7).

| batch entries | worst cycles (critical) | whole handler | deadline | margin | worst phase / Y |
|---:|---:|---:|---:|---:|---|
| 1 | 212 | 297 | 756 | **+544** | phase 7, Yc 98 |
| 2 | 291 | 376 | 756 | **+465** | phase 7, Yc 98 |
| 3 | 366 | 451 | 756 | **+390** | phase 7, Yc 98 |
| 4 | 447 | 532 | 756 | **+309** | phase 7, Yc 98 |
| 5 | 520 | 648 | 756 | **+236** | phase 7, Yc 98 |
| **6** | **646** | **731** | **756** | **+110** | **phase 7, Yc 98 / offset 8** |

Marginal cost ≈ **86.8 cycles per extra entry**; monotonic, and the executor was
verified to have performed exactly *n* sprite writes at each size.

For context, P1's best mid-screen measurement was ~322 cycles on a **one**-entry
batch. The six-entry case costs roughly **double** that, which is precisely why
it had to be built before the constant could be trusted.

---

## 8. `REUSE_LEAD` conclusion

**`REUSE_LEAD` stays at 12. It was not changed, and the measurement says it does
not need to be.**

```
worst six-entry merged batch, critical path   646 cycles
budget            REUSE_LEAD * 63             756 cycles
margin                                       +110 cycles  (1.75 raster lines)
stricter fetch deadline  11 * 63              693 cycles  -> +47 cycles
utilisation                                    85% of the budget
```

The constant was left alone until after measurement, as required. The budget was
never exceeded and never dangerously approached, at any batch size, any fine
phase, or any vertical position, so none of the "derive a smaller safe lead"
path applies.

**It remains conservative for smaller batches** — a one-entry batch finishes
with 544 cycles unused, 72% of its budget wasted — because a single lead must
cover the six-entry case. A per-batch lead computed by the builder would recover
most of that, but it makes the batch raster depend on batch membership, which is
a schedule-*shape* change rather than a tuning change. Deliberately left for
later, as P0 already noted.

---

## 9. Static-Y matrix summary

### Uniform spacing (30, 24, 22, 21, 20, 18, 16, 12)

| spacing | sprites | accepted | rejected | batches | same-slot gap |
|---:|---:|---:|---:|---:|---:|
| 30 | 6 | 6 | 0 | 1 | 180 |
| 24 | 8 | 8 | 0 | 3 | 144 |
| 22 | 8 | 8 | 0 | 3 | 132 |
| 21 | 9 | 9 | 0 | 4 | 126 |
| 20 | 9 | 9 | 0 | 4 | 120 |
| 18 | 10 | 10 | 0 | 5 | 108 |
| 16 | 11 | 11 | 0 | 6 | 96 |
| 12 | 15 | 15 | 0 | 10 | 72 |

**Every uniform spacing is fully accepted, and that is the result.** Six-way
round robin makes the same-slot separation `6 × S`, so even `S = 6` clears the
33-line gap. The uniform axis **cannot** exercise the reuse rule; it exercises
batch density only. It is retained so that claim is tested rather than assumed —
and it is the reason the clustered axis exists.

### Required classes

| class | fixture / case | result |
|---|---|---|
| no reuse | F0, uniform 30 | accepted, 1 batch |
| first reuse | F1 | accepted index 6 → slot 2 |
| repeated legal reuse | F2, uniform 12 | 8–9 reuse events, 9–10 batches |
| merged batch of 2 | F9 `T2` | 2-entry batch at raster 86 |
| merged batch of 3 | F8 `T3` | 3-entry batch |
| merged batch of 4 | F7 `T4` | 4-entry batch |
| merged batch of 5 | F6 `T5` | 5-entry batch |
| **merged batch of 6** | **F5 `T6`** | **6-entry batch, executed** |
| repeated merged reuse | F14 `T6X3` | **three** 6-entry batches per frame |
| legal but conservatively rejected | F12 (gap 21), F13 (gap 32) | rejected, counted in `MRG` |
| physically unsafe | F3, F12 (gap 20) | rejected, counted in `UNS` |
| batch-merge boundary | F11 `SPLIT` | Y and Y+1 do **not** merge (3 batches) |

### Exact boundaries

| gap | verdict | classification |
|---:|---|---|
| 20 | rejected | **physically unsafe** (`SPRITE_HEIGHT - 1`: the sprites genuinely overlap) |
| 21 | rejected | **physically legal, conservatively rejected** (`SPRITE_HEIGHT`) |
| 32 | rejected | physically legal, conservatively rejected (`MIN_REUSE_GAP - 1`) |
| **33** | **accepted** | **legal and rendered** (`MIN_REUSE_GAP` — the conservative boundary) |
| 34 | accepted | legal and rendered |

Fixtures 12 and 13 are written in terms of `SPRITE_HEIGHT` and `MIN_REUSE_GAP`,
so they track the constants automatically if `REUSE_LEAD` is ever changed.

---

## 10. Vertical sweep

**Structural:** fixture 5 shifted down one raster at a time, offsets **0…120**
(121 positions) — the merged batch walks from raster **86 to raster 206**,
sprites from Y 60 to Y 238. Every offset was compared field by field against the
model, and **every one built a six-entry merged batch**: 121/121 clean.

This is also the "cluster straddling the aperture" case: at offset 0 the leaders
sit at the top of the visible band, and at offset 120 the reusers run to raster
238, into the lower border region.

**Timed** (natural scrolling, so each row is already the worst over all eight
phases at that position):

| offset | batch raster | worst critical | margin |
|---:|---:|---:|---:|
| 0 | 86 | 640 | +116 |
| 8 | 94 | **646** | **+110** |
| 16 | 102 | 640 | +116 |
| 24 | 110 | 646 | +110 |
| 32 | 118 | 639 | +117 |
| 40 | 126 | 646 | +110 |
| 48 | 134 | 639 | +117 |
| 56 | 142 | 646 | +110 |
| 64 | 150 | 639 | +117 |
| 72 | 158 | 646 | +110 |
| 80 | 166 | 639 | +117 |
| 88 | 174 | 646 | +110 |
| 96 | 182 | 639 | +117 |
| 104 | 190 | 646 | +110 |
| 112 | 198 | 639 | +117 |
| 120 | 206 | 646 | +110 |

**Absolute vertical position barely matters**: 639–646 cycles across the whole
band, a spread of 7 cycles. This follows directly from the DMA finding in §6 —
the only variable is the badline phase relationship, and that is set by YSCROLL,
not by where on the screen the batch sits.

**Smallest timing margin observed anywhere in P2: +110 cycles**, at fine phase 7,
reached both by fixture 5 at offset 0 with the phase pinned and by offsets ≡ 8
(mod 16) under natural scrolling. Frozen as fixture 15 (`WORST`) at offset 8:
leaders Y 68–73, reusers Y 106, merged batch on raster 94.

---

## 11. Classification counts

145 distinct cases (16 named fixtures, 8 uniform spacings, 121 sweep offsets):

| classification | sprites |
|---|---:|
| legal and rendered | **1682** |
| legal but conservatively rejected | **4** |
| physically unsafe and rejected | **4** |
| **renderer failure** | **0** |
| **harness failure** | **0 outstanding** (3 found and fixed — §18) |

No case was conflated: conservative rejection is counted separately from
physical impossibility everywhere, in the engine (`statRejMargin` vs
`statRejUnsafe`), in the model (`LEGAL_REJECTED` vs `UNSAFE_REJECTED`) and on
screen (`MRG` vs `UNS`).

---

## 12. Worst legal case, boundaries, failures

- **Worst measured legal geometry** — fixture 5 / 15 at fine phase 7: six-entry
  merged batch, **646 cycles, +110 margin**. Permanent fixture **15 (`WORST`)**.
- **Conservative boundary** — gap 32 rejected / gap 33 accepted. Permanent
  fixture **13 (`BNDCONS`)**.
- **Physical boundary** — gap 20 unsafe / gap 21 legal-but-rejected. Permanent
  fixture **12 (`BNDPHYS`)**.
- **Renderer failures** — **none**. No smallest reproducer to preserve.

---

## 13. Page / pointer coherence under P2 stress

15,500-20,000 frames per fixture under natural scrolling, with six slots reprogrammed
once (`T6`) or three times (`T6X3`) per frame:

| counter | `T6` | `T6X3` |
|---|---:|---:|
| frames | 20,004 | 15,562 |
| coarse steps | 2,500 | 1,945 |
| page flips | 2,500 | 1,946 |
| A→B / B→A | 1,250 / 1,250 | 973 / 973 |
| six-entry batches executed | 20,003 | **46,683** |
| mid-screen batches of any other size | **0** | **0** |
| `$d018` / software-page mismatch | **0** | **0** |
| pointer-destination mismatch | **0** | **0** |
| late recoveries (`statLate`) | **0** | **0** |
| longest late run | **0** | **0** |
| back-page-late | **0** | **0** |
| publication skips | **0** | **0** |
| flip raster min / max | 250 / 250 | 250 / 250 |
| fine phases exercised | all 8, evenly | all 8, evenly |

Displayed-page sprite pointers matched the CURRENT schedule for all six slots,
and the pointer destination belonged to the page `$d018` was actually
displaying.

---

## 14. Complete P0/P1 regression

All P0 and P1 tests remain mandatory and were re-run against the final P2
binary, in one sequential run.

| suite | checks passed | failures | result |
|---|---:|---:|---|
| `test_p0.py` | 85 | 0 | **ALL PASS** |
| `test_p1.py` | 59 | 0 | **ALL PASS** |
| `test_p2.py` | 117 | 0 | **ALL PASS** |

**P0** — schedule builder vs independent model on all five fixtures; six-slot
round robin; first reuse at accepted index 6; memory layout; executor timing.

```
handler cost: min 279  median 328  max 886 cycles
frame batch (6 entries, line 250): max 886 cycles
mid-screen batches: max 353 cycles over 2,064 samples
```

**P1** — 19,556-frame stress run, fixture 2:

```
renderer batches         175,996
coarse steps             2,444      page flips 2,445 (A->B 1,222, B->A 1,223)
page A / page B frames   9,780 / 9,776
fine-phase counts 0..7   [2444, 2444, 2444, 2444, 2445, 2445, 2445, 2444]
page mismatches          0
pointer mismatches       0
deadline misses (late)   0   longest run 0
back page late at flip   0
publication skipped      0
flip raster min/max      250 / 250   over 3,910 flips
mid-screen batches       min 279  max 353 cycles over 18,904 samples
frame batch              min 832  max 896 cycles
```

Renderer immutability still holds: with the main thread parked on a
jump-to-self, frames keep rendering correctly from CURRENT alone, with no
coherence fault.

### Two P0/P1 numbers moved, and why

P1 previously reported a worst mid-screen batch of **322** cycles; it now reports
**353**. The frame batch moved 871 → 896. Both are the **whole-handler**
measurement, and both moved because P2 added ~25 cycles of `batchSizeHist`
bookkeeping plus ~1 cycle from an inverted branch — all of it **after** the last
VIC register write. The critical path is unchanged. Nothing regressed; the
diagnostic is simply in the binary now, and the numbers are honest about it.

---

## 15. Manual acceptance procedure

**Not yet performed. This is what remains before P2 can be called GREEN.**

```sh
make run
```

Normal speed, no monitor, no warp, real window. Press **SPACE** five times to
reach **fixture 5**, the six-entry merged batch, and leave it running for
several minutes.

Watch for:

- **six** boxes side by side on one row, six distinct numerals, six distinct
  colours, none overlapping — fewer than six at any instant is a failure;
- row 22's **`B6`** counter climbing continuously (six-entry batches actually
  executed). If it freezes while the playfield scrolls, the merged batch has
  stopped running;
- row 22's **`MXB`** reading 6;
- no flicker, tearing, screen snap, stale/duplicate/skipped rows, or mixed A/B
  page letters;
- nothing that correlates with a page flip or coarse step.

Then **fixture 14** (`T6X3`) — three such rows, 24 sprites, every slot
reprogrammed three times per frame. The endurance case.

The measured margin is **110 cycles, under two raster lines**, so this is
exactly the fixture where a human watching a non-warp run matters most.
Automated results do not override it.

### Supporting visual evidence (not a substitute)

Headless screenshots were taken through the monitor as a sanity check. They show
the right thing:

- **fixture 5** — `LOG 0C  MXB 06  OFF 00  B6 0144  PH7  PGA`, with **six**
  distinct numerals in six distinct colours side by side on one row;
- **fixture 14** — `LOG 18  MXB 06`, `ACC 18  REU 12`, four rows of sprites;
- **fixture 12** — `ACC 06  MRG 01  UNS 01`, only the six leaders drawn, both
  candidates correctly rejected.

These are single captured frames from a warp/stepped machine. They cannot show
flicker, tearing, intermittency or anything that only appears after a long
dwell — which is the whole failure class this project exists to catch. They
support §15; they do not replace it.

---

## 16. VICE process hygiene

`pgrep -fl x64sc` before the suites: **none running**.

Every launch is owned by PID, retained, terminated and reaped in `try/finally`,
and verified gone. No broad `pkill`. Other `x64sc` processes are reported and
left alone. Final check: **no test-owned VICE process remains.**

### Focus theft — fixed

During this work a suite's VICE window **took the macOS keyboard focus from
another application the user was working in**, and the user had to kill the
emulator mid-run. The aborted run then presented as a `BrokenPipeError` with
VICE "exiting rc=0" — indistinguishable from a harness or renderer fault.

All automated launches now pass **`-console`**: the full machine, no UI, no
window, no focus. This was **verified timing-faithful before being relied on**,
by running the P0 executor timing section both ways on the same binary:

```
windowed   min 247   median 289   max 871   mid-screen max 322
-console   min 247   median 289   max 871   mid-screen max 322
```

— identical, over identical entry lines and sample counts. The monitor
`screenshot` command still renders correct frames, so `tools/capture_p0.py`
needs no window either. **`make run` is unchanged and still opens a real
window**, because manual acceptance is a human watching a real display.

---

## 17. Build / test hygiene and disk usage

Fixed build outputs only; no per-run directories. Trace logs go to
`/tmp/6502-engine-p2` and are swept automatically; the suite asserts the scratch
directory is empty before it exits.

```
$ du -sh build/
 64K   build/

repo excluding .git   540K
repo total (du -sh .) 740K

$ ls -d /tmp/6502-engine-*
(none -- all scratch removed)
```

`build/` holds exactly `engine.prg`, `main.sym` and `main.vs`. No per-run
directories were created at any point.

---

## 18. Harness faults found and fixed

Three genuine harness faults were found. Under this project's rules they had to
be fixed before any conclusion was drawn, and none was a renderer fault.

**1. Stale-buffer reads.** `buildSchedule` latches `schedNext` once at entry;
the frame IRQ can swap buffers *during* the build the harness is driving. The
schedule was then read from the wrong buffer, returning the *previous* case's
data. It presented as four unrelated fixtures disagreeing with the model while
their accepted/batch **counts** — which are not buffer-indexed — matched
perfectly, and that asymmetry is what identified it. Fixed by disabling the
raster IRQ during structural inspection, as `test_p0.py` already did.

**2. Deleted-but-open trace log → deadlock.** The harness deleted the VICE trace
log between retries. On macOS, unlinking a file VICE still has open does not
stop VICE writing to it: the trace poured into an orphaned inode no path points
at, the harness read nothing, and the emulator burned 80% of a core writing a
log it could never be asked about, eventually failing to service the monitor
socket. Symptoms were a confident **"0 samples"** — which looks exactly like a
renderer that stopped executing batches — followed by a hang. Fixed by writing
each attempt to its own file, **never** deleting a log while its VICE lives, and
sweeping only after the process is reaped. A hard wall-clock bound was added so
a collection can fail a test but never stall the suite.

**3. Measuring a schedule the executor had not adopted yet.** `buildSchedule`
writes the NEXT buffer and `publishSchedule` only *arms* the handover; the
executor keeps rendering the previous schedule until a frame IRQ adopts it.
Measuring immediately timed the *previous* fixture — a one-entry batch came back
reporting six sprite writes and a six-entry cost. Fixed by making the harness
run the machine and verify the **CURRENT** buffer before any measurement.

A fourth correction was to a **hypothesis**, not the harness: the suite asserted
that phases with two badlines in the nominal window cost more than phases with
one. The measurement refuted it (§6) and the check was rewritten around the
critical path. The wrong prediction is recorded in the source comment rather
than quietly deleted.

---

## 19. Test inventory

New automated P2 evidence, all compared against an independent model:

- accepted / rejected **with reason** (unsafe vs conservative), per fixture and
  per sweep case;
- slot assignment, and that it stays inside the 2–7 pool;
- **same-slot predecessor** — verified by checking entry *i* and entry *i-6*
  really hold the same hardware slot in the built schedule;
- **reuse gap** per entry, recomputed from the engine's own schedule and checked
  against the rule;
- batch raster, batch first/count, and **complete schedule coverage**
  (`sum(count) == accepted`);
- `statMaxBatch` — widest mid-screen batch, checked against the model;
- `batchSizeHist` — mid-screen batch sizes the executor **actually ran**;
- per-batch sprite-write count measured on the machine by tracing `exPtrStore`;
- `MAX_SCHED` / `MAX_BATCH` never exceeded.

Retained P1 assertions, now under P2 stress: `$d018`/software-page mismatch 0,
pointer-destination mismatch 0, back-page-late 0, publication-skip 0,
displayed-page pointers match CURRENT, late-recovery count and longest late run
0, worst handler cycles and margin reported.

Run with `make test` (P0 + P1 + P2) or `make test-p2`.

---

## 20. Recommendation for P3

P3 introduces scripted moving Y positions while retaining all qualified P0–P2
machinery. What P2 hands it:

1. **A 110-cycle margin is the real constraint, and it is not large.** Anything
   P3 adds to the executor's per-batch path spends that margin directly. The
   `exWritesDone` probe exists so P3 can measure the critical path rather than
   the whole handler; use it.

2. **Moving Y breaks P2's DMA guarantee only if the builder's gap test is
   bypassed.** The rule `Y_i - Y_(i-6) >= 33` is what keeps the batch window
   DMA-free. As long as P3 feeds *moved* Y values through the same acceptance
   test each frame, the guarantee holds. If P3 ever pre-computes a schedule and
   then moves sprites underneath it, it does not — and that is the first thing
   P3 should test.

3. **Acceptance will start flickering frame to frame.** A sprite crossing the
   gap-33 boundary as it moves will be accepted one frame and rejected the next,
   appearing and disappearing. That is correct by P2's rules and will look like
   a bug. P3 needs an explicit policy (hysteresis, or accepting the flicker as
   documented behaviour) and a fixture that walks a sprite across the boundary
   one raster per frame.

4. **Reuse the ladder fixtures directly.** `T1`…`T6` give a batch-size axis with
   one controlled variable, and `T6X3` is the endurance case. A P3 script that
   holds geometry static should reproduce P2's numbers exactly; any divergence
   is P3's own cost.

5. **`MAX_SCHED` is now a live constraint.** `T6X3` sits exactly on 24 entries.
   The builder still stops adding batches at the cap rather than reporting an
   error — worth fixing before P3 generates geometry rather than reading it from
   a table.

6. Keep `-console` for automated suites and keep manual acceptance windowed.
