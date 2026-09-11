# P1 — Scrolling Renderer Proof

**Verdict: GREEN on automated evidence**, subject to the manual normal-speed
dwell in §14 that only you can sign off.

Both suites pass in full. The renderer's architecture is unchanged: P1 added a
second published record with the same shape as the schedule, and the executor
still consumes nothing but immutable per-frame state. `REUSE_LEAD` was **not**
adjusted — measurement says it did not need to be.

---

## 1. Files changed and added

```
ADDED
  src/scroll.asm                 the scroller: state, page regeneration,
                                 frame-record publication          (330 lines)
  tests/test_p1.py               P1 suite: scroller, page/pointer
                                 ownership, immutability, stress    (479 lines)
  reports/p1-scrolling-renderer-proof-report.md

CHANGED
  src/main.asm                   rewritten around a per-frame main loop;
                                 two-page memory map; page-parameterised HUD
  src/renderer.asm               frame record + one frame-boundary transaction;
                                 pointer destination as a patched operand;
                                 frame diagnostics; batch counter
  tests/test_p0.py               timing section: log-flush race fixed, sample
                                 count asserted, batch budgets split
  Makefile                       test-p1 target; test = test-p0 test-p1
  README.md                      P1 status, what P1 adds
  docs/qualification-ladder.md   P1 marked implemented; the decision recorded
  docs/manual-acceptance.md      P1 playfield, new fail conditions

UNCHANGED
  src/fixtures.asm, src/sprites.asm, tools/capture_p0.py
```

All five P0 fixtures are untouched and independently runnable.

**Nothing committed and nothing pushed by me.** The working tree carries all P1
work as modifications on top of your own commit `58d0913 "P0 complete"`.

## 2. Memory map

```
$0400-$07ff   screen page A            sprite pointers $07f8-$07ff
$0801-$080c   BASIC stub
$0810-$0a4d   main                     entry, frame loop, input, HUD
$1000-$1218   schedule builder
$1500-$1700   raster executor
$1800-$18fc   fixtures
$1900-$1adc   scroller                             <- new
$2000-$23ff   sprite bitmaps (16 x 64)
$2800-$2bff   screen page B            sprite pointers $2bf8-$2bff   <- new
$c000-$c212   schedule buffers + frame records
```

Two things about this layout are load-bearing:

**The code at `$1000-$1fff` is invisible to the VIC.** In bank 0 the VIC sees
the character ROM at `$1000-$1fff`, so the schedule builder, the executor, the
fixtures and the scroller can live there while the VIC reads glyphs. Both pages
use character base `$1000` (`$d018` CB bits `%010`), which is the stock C64
arrangement, not a trick. `$d018` is therefore `$14` for page A and `$a4` for
page B.

**Page B at `$2800` clears the sprite bitmaps at `$2000-$23ff`.** Asserted by
test, not by eye — the previous project put score bitmaps on top of the enemy
sprite pool because both were 64-byte aligned and every alignment guard passed.

## 3. Scroller architecture

The smallest scroller that genuinely exercises the hardware. It is a diagnostic
surface, not artwork.

```
page P displays world rows [worldRow .. worldRow+24]

fine scroll counts DOWN 7..0, one pixel per frame   -> playfield moves UP
on the 0 -> 7 wrap the content must jump one row, so:
        worldRow += 1
        flip to the other page, already holding [worldRow+1 .. +25]
        start rebuilding the page just vacated with [worldRow+2 .. +26]
```

**Coarse step and page flip are the same event**, once every 8 frames.

**The back page is regenerated, never copied.** Every row is written from its own
world row number, so a stale, duplicated or skipped row cannot survive: the row
prints its own identity. A copy-and-shift reproduces whatever was already wrong.

Regeneration is spread at `ROWS_PER_TICK = 5` rows per frame — 25 rows over the
8 frames available, with margin. A single 25-row burst is ~12,000 of the 19,656
cycles in a frame, which leaves no room for anything the main thread later
grows. `scrollLate` counts any coarse step that arrives with the back page
unfinished; it reads 0.

**Row format** (40 columns):

| columns | content | what it catches |
|---|---|---|
| 0-1 | world row number, low byte, hex | stale / duplicate / skipped / out-of-order rows |
| 3 | `A` or `B`, the page this row was built into | a torn page flip |
| 5-39 | solid bar when `world row mod 4 == 0`, else blank | coarse steps, countable by eye |
| 6 + (world mod 32) | a `*` marker | a clean diagonal; kinks mean wrong rows |

**Colour RAM is written once at startup and never again.** There is only one
colour RAM; it cannot be double buffered, so anything changing it per coarse
step would tear across a page flip with no way to publish it atomically. The
characters scroll through a stationary colour field instead.

**`RSEL=0` (24-row mode)** is deliberate. Scrolling 25 matrix rows through a
24-row window hides the 8 pixels of scroll slack in the border. In 25-row mode
that slack displays as an idle strip — exactly the meaningless artefact that
makes a human distrust a manual run.

## 4. Frame / page publication ordering

There is **one** frame-boundary transaction, in `exFrame`, at raster 250 in the
lower border. Everything that decides what a displayed frame *is* happens there
and nowhere else.

```
MAIN THREAD, once per displayed frame (paced by frameCounter):

  1. hudTick      writes the page on screen RIGHT NOW. dispPage still names it,
                  because scrollTick has not run yet this frame.
  2. regenTick    rebuilds the BACK page, which nothing is displaying.
  3. scrollTick   advances the scroll; only here can dispPage change;
                  publishes the frame record:  framePending = 1

FRAME IRQ (raster 250), in this order and atomically with respect to the frame:

  4. adopt the frame record      (swap frameCurrent/frameNext if pending)
  5. sta $d011                   fine scroll, RSEL, DEN, RST8=0
  6. sta $d018                   the screen matrix for the whole frame
  7. sta exPtrStore+2            THE sprite-pointer-table destination
  8. adopt the schedule record   (swap schedCurrent/schedNext if pending)
  9. sta $d015 / $d01c           frame-wide sprite state
 10. batch 0, then batches 1..n on their own raster IRQs
```

No main-thread write ever lands on the page the VIC is fetching, because step 2
only ever touches the page step 3 has not yet flipped to. The page decision is
made at exactly one point per frame.

The frame record is **double buffered with a one-byte pending flag**, for the
same reason the schedule is: the IRQ must never observe a half-updated set in
which `$d018` names one page and the pointer destination names the other.
`publishSkip` counts any attempt to publish over an unadopted record; it reads 0.

The engine answers *"which screen and pointer page owns this displayed frame?"*
with one stable value: `curPage`, latched at step 4.

## 5. Pointer-table ownership

"Write both tables every time" was **not** adopted.

`$07f8` and `$2bf8` share the low byte `$f8`. The executor has exactly one
pointer store in the entire program:

```asm
    lda schedPtr,y
exPtrStore:
    sta PTR_A,x        ; operand HIGH byte patched once per frame by exFrame
```

The frame IRQ writes that single byte at step 7 above, at the same instant it
writes `$d018`. A raster batch cannot choose a destination even in principle —
there is one store instruction, and its target is fixed before the first batch
of the frame runs.

Four invariants, all asserted:

1. **one unambiguous destination per frame** — one writer of `exPtrStore+2`,
   checked at source level;
2. **it corresponds to the page `$d018` actually selects** — checked *in the
   engine* every frame by deriving the expected high byte from the `$d018`
   register rather than from our own intention, so it cannot agree with itself
   by construction;
3. **batches do not guess** — one `sta PTR_x,x` in the source, patched from one
   place;
4. **no gameplay state consulted mid-frame** — §6.9 below.

## 6. Automated test results

`make test` runs both suites. Both report **ALL PASS**.

### P0 regression — no coverage lost

Every P0 structural, schedule-model, acceptance/rejection and timing check still
passes against the P1 build: all five fixtures match the independent Python
model on accepted / reuse / margin-rejected / unsafe-rejected counts, slot
round-robin, `slot*2`, batch lines, batch first/count, and coverage.

Two P0 test defects were found and fixed while re-running it. Both **increase**
coverage:

**The timing section could silently under-sample.** It read the VICE trace log a
fixed 0.5s after `log off`. VICE flushes lazily, so it sometimes parsed only the
first line or two and then reported one lucky measurement as the worst case.
That is how P0's report came to say `IRQ entry lines observed: [250]` and
`min 666 median 666 max 666` for a nine-batch frame — it had measured a single
batch. The read now waits for the file to settle, and the suite asserts a
minimum sample count and that **every armed batch line was sampled**. Entry
jitter is handled honestly: a raster IRQ is entered 0-1 lines after the armed
line, so 127 is observed as 127 or 128.

**The budget assertion conflated two different deadlines.** See §10.

### Harness reliability — four findings, all of them bugs in the harness

None of these were engine faults. All four produced *confident wrong numbers*,
which is the failure mode this repository treats as worse than a red test.

1. **The VICE monitor returns from `x` on a prompt echo, not on the actual
   stop.** So "step a breakpoint 300 times" does not reliably advance 300 stops;
   runs were observed where it advanced a handful of frames and the timing
   section then reported a worst case computed from ten samples. Both suites now
   **free-run with tracing** (which does not halt the machine) and assert a
   minimum sample count. Sample counts went from ~300 to ~21,000.

2. **A dropped `delete` reply leaves a breakpoint armed.** Every subsequent `x`
   then halts instantly on it, and the stress run reports zero frames — looking
   exactly like a dead engine. `free_run` now verifies the frame counter is
   actually advancing before it counts a slice, and fixture selection clears
   every checkpoint before handing back.

3. **Fixture selection was never verified.** A dropped poke silently measured
   the previous fixture. It is now checked against the independent model and
   retried.

4. **`pgrep -fl x64sc` matched the grep command reading its own output**, which
   reported a harmless shell pipeline as a stray emulator. The check now matches
   the executable, not any command line containing the string.

Three engine-side counters were also found to be too narrow, each of them
silently under-reporting rather than failing: `finePhase` (8-bit, wrapped after
~34 seconds), `batchCounter` (16-bit, understated a stress run by 4x), and the
fault counters, which now **saturate at `$ff`** so a long run cannot wrap one
back to a clean-looking zero.

### P1 suite

| section | what it proves |
|---|---|
| 1 | memory map: pointer tables inside their matrices, shared low byte, `$d018` decodes to the right base, page B clear of the sprite bitmaps, no symbol inside either matrix |
| 1b | single-writer invariants at source level: one `sta $d018`, one pointer store, one writer of `exPtrStore+2` |
| 2 | the deterministic stress run (§7-§9) |
| 3 | the displayed page carries the world rows it should |
| 4 | displayed-page pointer bytes match the CURRENT schedule |
| 5 | page-flip atomicity |
| 6 | renderer immutability with the main thread frozen dead |
| 7 | timing under the scrolling load |

## 7. Fine-scroll counts

From the 25-second warp stress run on fixture 2 (**23,168 physical PAL frames**):

```
fine-phase counts 0..7   [2896, 2896, 2896, 2896, 2896, 2896, 2895, 2896]
spread                   1
```

Every phase exercised ~2,900 times. The spread of 1 is the deterministic
1px/frame rate: the run simply ended mid-cycle.

The counters are **16-bit per phase**. They were 8-bit in the first draft and
wrapped after 256 frames per phase — about 34 seconds — silently under-reporting
coverage. Caught by the stress run disagreeing with itself, not by inspection.

## 8. Coarse-scroll and page-flip counts

```
physical PAL frames      23168
renderer batches         208504    (9.00 per frame, as scheduled)
coarse steps             2896
page flips               2896      (A->B 1448, B->A 1448)
frames displayed page A  11584
frames displayed page B  11584
world row reached        4347      (cumulative from boot)
flip raster min / max    250 / 250
back page late at flip   0
publication skipped      0
```

* one coarse step per eight frames, none missed or duplicated
  (23,168 / 8 = 2,896);
* **world row advanced exactly once per coarse step** — `worldRow == coarseCount`
  exactly, which is the direct no-missed / no-duplicate / no-jump assertion;
* every coarse step flipped the page (`flips == coarse`);
* both matrices displayed, **exactly** 11,584 frames each;
* A→B and B→A both happen 1,448 times and sum exactly to the flip count;
* the batch counter tracks nine batches on every single frame;
* page frames account for **every** displayed frame (`A + B == frames`).

## 9. Pointer / page coherence

**Zero mismatches**, on every measure:

```
$d018 / software-page mismatches   0     (checked in-engine, every frame)
pointer-destination mismatches     0     (checked in-engine, every frame)
```

Both are engine self-checks that run at every frame IRQ and **saturate at $ff**
rather than wrapping — a wrapping 8-bit fault counter can read zero after a long
run and look clean.

The `$d018` self-check masks bit 0, which is unused and **reads back as 1
whatever you wrote**. Measured, not assumed: it made the check fire on all
23,000 frames of the first run.

Additionally, sampled directly through the monitor:

* at a frame boundary, `curPage`, `dispPage` and the live `$d018` all agree;
* every displayed row prints its own world row number, and **every visible row
  carries the same page letter** — no torn flip;
* after the last batch of a frame, every mux slot's pointer byte **on the
  displayed page** equals the last schedule entry assigned to that slot
  (fixture 2: slots 2-7 hold `$8c $8d $88 $89 $8a $8b`), and all six slots were
  written. The inactive page may hold stale values; that is not a failure.

**Page-flip atomicity.** The engine records the raster of **every** flip and
keeps the running minimum and maximum, sampled at frame-IRQ *entry*:

```
flip raster min / max    250 / 250      over 4,347 flips
```

Not one flip in the whole run deviated by a single raster line. Together with
the source-level check that **exactly one `sta $d018` exists in the program**
(labelled `exSetD018`, inside `exFrame`), and the fact that `exFrame` runs only
when `curBatch == 0` — before any batch programs a sprite — a flip cannot occur
inside a batch, and specifically cannot land between an entry's Y write and its
pointer/colour writes.

This replaced a sampled watchpoint/trace approach that was tried first and
abandoned: VICE's remote monitor returns from `x` on a prompt echo rather than
on the actual stop, so the "samples" it collected were whatever raster the next
command happened to halt on. A counter that sees every flip is both cheaper and
far stronger than forty sampled stops. That finding is itself worth keeping —
several of this session's early harness failures had the same root cause.

## 10. Timing measurements

Measured under the scrolling load, across **all eight fine-scroll phases** — the
badline phase moves with `YSCROLL`, so this is a genuinely harder timing
environment than P0's.

```
handler pairs sampled    21304
fine phases active       8 of 8 during the window

frame batch  (line 250)  min 817   max 881 cycles  (13.98 raster lines)
mid-screen batches       min 247   max 322 cycles  ( 5.11 raster lines)

  line 115: n=2367  min=248  max=292      line 175: n=2367  min=248  max=292
  line 127: n=2367  min=261  max=322      line 187: n=2367  min=248  max=300
  line 139: n=2367  min=248  max=292      line 199: n=2243  min=253  max=316
  line 151: n=2367  min=248  max=292      line 250: n=2368  min=817  max=881
  line 163: n=2367  min=247  max=299
```

(Line 200 also appears with 124 samples: that is line 199's IRQ entered one
raster late, the ordinary 0-1 line entry jitter, not a separate batch.)

### The two deadlines are different, and P0 conflated them

P0 asserted one lumped budget — `REUSE_LEAD * 63 = 756` cycles — against every
batch. That is the wrong test for the frame batch, and it only ever held because
P0's truncated log happened to fit under it.

* **Mid-screen batches** are the `REUSE_LEAD` case: the batch must finish before
  the sprite it is reprogramming reaches its own Y. Budget 756 cycles.
  **Worst measured: 322 cycles — 43% of the budget.**
* **The frame batch** fires in the lower border at raster 250 and its sprites are
  not fetched until the earliest fixture Y, raster 55, on the *next* frame:
  `(312 - 250) + 55 = 117` raster lines = **7,371 cycles**. The suite asserts a
  deliberately tight 2,000-cycle ceiling against that.
  **Worst measured: 881 cycles — 12% of the real deadline.**

The suite now asserts these separately and prints both.

### Change from P0, and why

The frame batch grew from ~666 to ~881 cycles. That is the frame-boundary
transaction (adopting the record, `$d011`, `$d018`, the pointer patch) plus
`frameDiagnostics` — the permanent in-engine self-checks and counters. It is
spent in the place with an 8.6× margin, and it buys page/pointer coherence
checking on every frame of every run forever. Mid-screen batches, which are the
ones with a real margin problem, grew only from 300 to 322 cycles.

### `REUSE_LEAD` is unchanged

`REUSE_LEAD = 12` remains correct and was **not** adjusted. The worst mid-screen
batch under full scrolling load uses 43% of its budget. Nothing about scrolling
required a change, so nothing was changed.

### Badline interaction

The `YSCROLL` value selects which rasters are badlines, so as the fine scroll
cycles, each batch line moves in and out of badline coincidence. That is visible
directly in the spread: line 127 ranges 261-322 (61 cycles ≈ one badline's worth
of VIC cycle theft), while lines that never coincide sit flat at 248-292. The
maxima above are therefore worst-case-over-all-phases, not a lucky sample.

### Deadline misses

```
deadline misses (late)   0     longest consecutive late run   0
```

`exLate` — the executor's late-IRQ recovery path — was **never taken** across
the whole stress run. Instrumented permanently (`statLate`, `maxLateRun`).

## 11. VICE process ownership and cleanup

Both suites own every PID they launch, reap them in `try/finally`, and verify
none remain:

```
P0:  launched and reaped: 2 PIDs
P1:  launched and reaped: 3 PIDs
     other x64sc processes (NOT ours, left alone): none
```

The ownership check was also fixed during this work. It previously matched
`pgrep` output against the string `6502-engine`, which **also matches a manual
VICE session you have open on this project** — it reported your own session as a
leaked test process, one step away from something killing it. Ownership is now
by recorded PID, and other `x64sc` processes are listed explicitly as *not ours*.

No `pkill`. No `open -a`. No focus stolen during automated tests.

## 12. Disk usage

```
build/           228K      engine.prg, engine.d64, main.vs, main.sym  (4 files)
repo (no .git)   692K
.git             236K
/tmp             transient trace logs and screenshots, deleted after use
```

`build/` holds only current artefacts. No per-run directories were created.

## 13. Known limitations

- **The HUD rides the fine scroll.** Rows 1, 2 and 23 sit inside the scrolling
  matrix and wobble by up to 8 pixels. Holding them still needs a mid-screen
  `$d011` write — a raster split, which is P8. Deliberately not done here.
- **Rows 0 and 24 are the scroll slack** and are clipped by the border under
  `RSEL=0`. Rows 1-23 are always fully visible. The bottom bar is at row 23 for
  that reason.
- **Colour RAM is static.** A scrolling colour field needs a second buffer that
  the hardware does not have; solving it needs a per-row colour write scheme
  that P1 deliberately does not attempt.
- **Mid-screen batches are all single-entry.** No P1 fixture produces a merged
  six-entry mid-screen batch, so the case `REUSE_LEAD` is actually sized for is
  still argued rather than measured. This is P2's job (§15).
- **One scroll rate.** 1 px/frame, fixed. Variable rates are not exercised.
- **Vertical only.** No horizontal scroll, no `$d016`.
- **The scroller never wraps its 16-bit world row** in a run of realistic length;
  behaviour at the 65,536-row boundary is untested.
- **The harness cannot observe a freely-running non-warp machine**, because any
  monitor command halts the emulator. This is exactly why §14 is not optional.

## 14. Manual acceptance procedure

Full detail in `docs/manual-acceptance.md`. This is the authoritative test and
automated results do not override it.

```sh
cd /Volumes/SSD/dev/C64/6502-engine
make run          # normal speed, no monitor, no warp, joysticks detached
```

Launch through `make` or the VS Code task, never a bare `x64sc`: `VICE_OPTS`
detaches both joystick devices, because a joystick keyset can otherwise bind the
host SPACE key to an emulated joystick and fixture selection goes silently dead.

Then:

1. **Confirm SPACE works.** Press it; the block after `KEY` on row 23 must light
   while it is held, and `FIXTURE n` must advance 0→1→2→3→4→0.
2. **Cycle to fixture 2** and leave it running for several minutes.
3. **Watch the left-hand hex column.** It must count upward by exactly one per
   row, smoothly, forever.
4. **Watch the page-letter column (column 3).** Every visible row must show the
   same letter. It flips wholesale between `A` and `B` every 8 frames. A mixture
   of `A` and `B` on screen at once is a torn page flip — RED.
5. **Watch the `*` diagonal and the bars.** The diagonal must stay straight; the
   bars must march at a constant rate with no snap at a coarse step.
6. **Watch the sprites.** Fourteen boxes `0`-`D`, each its own colour, each
   showing its own logical index. A wrong numeral, a duplicate, a wrong colour,
   flicker or tearing is RED — as is any corruption that only appears at a page
   flip.
7. **Dwell.** At least 30 seconds per fixture, and several minutes on fixture 2.
   The failure this project exists to catch is intermittent.

Expected on row 2: `SCR f  ROW wwww  PG A  CRS cccc` — fine phase counting 7
down to 0, world row and coarse count climbing, page letter alternating.

**Expected and not a fault:** the three HUD rows wobbling up to 8 pixels with the
fine scroll; sprite boxes covering part of a HUD label.

## 15. Recommendation for P2

**Do not change the renderer or the scroller.** P1 leaves the architecture ready:
the scroller runs unattended from the frame record, the executor consumes only
CURRENT, and fixture selection is a single byte. P2 sweeps geometry against
exactly this machine.

**The one gap P1 hands to P2.** Every mid-screen batch in every P1 fixture is a
*single entry*, so the six-entry merged batch that `REUSE_LEAD = 12` is sized for
has still never been executed. The 43%-of-budget figure in §10 is therefore the
easy case. P2's first job is to produce the hard one:

> six sprites at Y..Y+5, then six more all sharing a single Y further down —
> which forces a six-entry merged batch mid-screen, on a badline, at every fine
> scroll phase.

If that measures near 756 cycles, `REUSE_LEAD` becomes a measured number rather
than an argued one. If it exceeds it, P2 has found the first real renderer limit
and `REUSE_LEAD` should move — with the measurement written next to it.

**Build P2's matrix on the axes already documented** in `docs/p2-static-y-matrix.md`,
and note that axis 3 (scroll phase) is now available for real: pin the fine
scroll to each of 0-7, then free-run, then sweep across a coarse step and a page
flip. The engine already counts fine phases, coarse steps and flips, so a P2
fixture can be held at a chosen phase and the counters will prove it.

**Add to the suite at P2:** worst merged-batch cost per fine-scroll phase, and
the same page/pointer coherence counters asserted at zero under the heavier
geometry. They cost nothing extra — they already run on every frame.

**Do not start P3** until P2's matrix passes both automatically and on a long
non-warp dwell.
