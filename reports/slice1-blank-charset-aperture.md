# Slice 1 — blank-charset pixel-smooth aperture

**Technical result: the guard-row aperture is gone. Terrain is clipped by a
blank character set at two fixed rasters, 55 and 248; matrix rows 0 and 24
carry ordinary world content again; and the picture steps exactly one pixel per
frame at every fine-scroll phase.** The 6.25 Hz pop had a single cause — an
aperture edge at `56 + YSCROLL` that moved with the scroll — and the edge no
longer moves, because it is a raster and not a row.

Not visually GREEN. That is the manual test in §18.

HUD, batch-0 handoff and sprite ownership are untouched, as the brief requires.

---

## 1. Memory allocation

```
$3800-$3fff   BLANK character set, 2 KB of zeros   <- new
$3fff         the VIC's idle byte, inside it by construction
$2c00-$2f1d   raster executor code                 <- MOVED from $1500
$3000-$37ff   free
```

`CB = %111` selects `$3800`; the real charset stays at `CB = %010` (`$1000`,
the character ROM image the VIC sees in bank 0). Only bits 3-1 of `$d018`
differ between them, so the VM bits still name the page.

Zeroed at run time by `clearCharset`, called from `entry` **before anything
enables the display**, not by a `.fill` segment: a segment would put 2 KB of
zeros in the PRG and force KickAssembler to emit the whole `$2800-$37ff` gap
with it, zeroing screen page B at load for no reason. Power-on RAM is not zero
on real hardware and nothing here relies on the emulator being kind.

**The executor had to move.** The two split phases and their instrumentation
grew it from `$1500-$17xx` past `$1800`, where the fixture tables live;
KickAssembler caught the overlap and refused to build. `$2c00` is the
documented free region and leaves 3 KB.

## 2. Assembler guards

```asm
.if (BLANK_CHARSET != $3800)                  { .error "CB = %111 is $3800 and nothing else" }
.if ((D018_A & $f0) != (D018_A_BLANK & $f0))  { .error "page A VM bits differ between charsets" }
.if ((D018_B & $f0) != (D018_B_BLANK & $f0))  { .error "page B VM bits differ between charsets" }
.if (SCREEN_B + $400 > BLANK_CHARSET)         { .error "screen page B overlaps the blank charset" }
.if (BLANK_CHARSET + $800 > $4000)            { .error "blank charset leaves VIC bank 0" }
.if (* > BLANK_CHARSET)  { .error "the raster executor has grown into the blank charset at $3800" }
```

The last one matters most: the VIC really does fetch glyphs from `$3800`, so
code spilling into it would be **displayed**. The existing p5-tables guard
(`P5_TABLE_BASE + P5_TABLE_BYTES > SCREEN_B`) already protects the other side.
Verified free before use — the highest bank-0 segment is the p5 tables at
`$2400-$27ff`, then screen page B at `$2800-$2bff`.

## 3. Guard-row code removed

- `renderGuardRow` **deleted**, and the row-0 / row-24 dispatch in `renderRow`
  with it.
- The six `HUD_ROW_*` reservations in `renderRow` **deleted** (already switched
  off by `HUD_VISIBLE`).
- `renderRow`'s dispatch is now a single `jmp renderBackgroundRow`: every row
  is terrain, and there is deliberately **no second masking mechanism left
  anywhere**. If a row looks blank on screen it is because the charset clipped
  it, and for no other reason.

## 4. Page-letter diagnostic removed from visible terrain

Column 3 of every row carried `A` or `B`. At every page flip all 23 visible
rows changed one character at once — a whole column blinking 6.25 times a
second in the middle of the picture a human is being asked to judge. The A/B
forensic measured it as **88 of the 96 lines that differ across a flip**: the
largest single visual event on screen, and pure scaffolding.

Observability is moved off-screen, not deleted, and made **stronger**:

```asm
pageWorldLo:  .byte 0, 0      // world row each PAGE's matrix row 0 holds
```

The letter said only "these rows came from the same pass". `pageWorldLo` lets a
test predict the exact world row of every one of the 25 rows and check them
all — which `test_p1` and the aperture suite now do.

It is stamped with `worldRowLo` for the page just flipped **to**, not for the
back page. The first attempt stamped the back page, and for the one frame
between the software flip and the IRQ adopting it at raster 250 the
still-displayed page carried a stamp two coarse steps ahead of its own content.
The invariant that matters is the narrow one: *`pageWorldLo[p]` is correct
whenever `p` is the page being displayed.*

## 5. `exBottom` — border open and the bottom split

Replaces `exBorder`. Still armed at 243 (measured during the border work: 246
does not open the border reliably), and one poll now does both jobs.

```asm
exBottom:
    ldx frameCurrent
    lda frameD011,x
    ora #$08            // RSEL=1: the close at 247 misses
    sta $d011
    lda frameD018B,x    // blank charset, same page -- LOADED BEFORE THE POLL
    ldy $d012
    cpy #BOT_SPLIT_LINE
    bcs !split+         // already past 248: never spin a frame with I set
    ldy #BOT_SPLIT_LINE
!wait:
    cpy $d012           // 7-cycle loop
    bne !wait-
!split:
    sta $d018
    lda frameD011,x     // RSEL=0: the close at 251 misses too
    sta $d011
```

The border mechanism is unchanged: the flip-flop is only ever *set* by the RSEL
comparison in cycle 63 of line 247 (RSEL=0) or 251 (RSEL=1), so arriving with
RSEL=0, switching to 1 before 247 and back to 0 before 251 makes it miss both.

## 6. `exTop` — the top split

Armed at **52**, three lines of margin, because exactly one of lines 48..55 is
a badline and the handler must already be polling before 55 whatever the phase.

```asm
exTop:
    ldx frameCurrent
    ldy #TOP_SPLIT_LINE
    lda frameD011,x
    and #$07
    cmp #$07
    bne !target+
    ldy #TOP_SPLIT_LINE - 1     // YSCROLL = 7: split on 54 instead
!target:
    sty topTarget
    lda frameD018,x             // LOADED BEFORE THE POLL
    cpy $d012
    beq !split+
    bcc !split+
!wait:
    cpy $d012
    bne !wait-
!split:
    sta $d018
```

**The YSCROLL=7 case is a correctness fix, not an optimisation**, and it was
found by measurement — see §10.

## 7. Full-byte `$d011` handling

Both `$d011` writes take the **complete byte from the CURRENT frame record**
(`frameD011,x`), never a read-modify-write. Bit 7 of a `$d011` *read* is raster
bit 8, while bit 7 of a *write* is the raster-compare high bit: an RMW above
raster 255 would arm compare line `250+256` and the frame IRQ would never fire
again. It happened to be harmless at 243. It is not a thing to leave in place.

## 8. The four `$d018` values

| page | real charset | blank charset |
|---|---|---|
| A (`$0400`) | `$14` | `$1e` |
| B (`$2800`) | `$a4` | `$ae` |

Both are precomputed into the frame record (`frameD018` / `frameD018B`) by
`publishFrame`, rather than masked at run time: neither split can afford an
`AND`/`ORA` inside its few-cycle window, and a record carrying both values
cannot disagree with itself about which page it means.

Sequence per frame: `exFrame` (250) writes the newly adopted page with the
**blank** charset; `exTop` (54/55) switches that same page to **real**;
`exBottom` (248) switches it back to **blank**. `exFrame` is still the only
instruction that decides the VM bits.

## 9. Phase order

```
raster 243  exBottom   RSEL=1, poll to 248, $d018 = blank, RSEL=0, arm 250
raster 250  exFrame    adopt frame + schedule records, $d018 = new page BLANK,
                       pointer destination, $d015, then batch 0, arm 52
raster  52  exTop      poll to 54 (ys=7) or 55, $d018 = REAL, arm first batch
raster 68+  exBatch    mid-screen mux batches, unchanged
                       ... last batch -> arm 243
```

`exPhase` (`PH_FRAME` / `PH_TOP` / `PH_BATCH` / `PH_BOTTOM`) replaces
`exBorderPending`. **`exLate` now refuses to chase anything but a batch**: the
frame transaction and both splits are structural, and running one early would
put a `$d011`/`$d018` write at an arbitrary raster — the FIX 16 failure class.

## 10. Raster/cycle timing, and a real defect the instrumentation caught

`topSplitMin/Max`, `botSplitMin/Max` and `edgeLate` record where each split
**actually landed**. Over a clean free-run:

```
                                    frames    top      bottom   edgeLate
boot / fixture 0                      4223    55..55   248..248        0
MAXCAP (first build)                  3800    55..56   248..248       39
MAXCAP, same IRQs, sprite DMA OFF     8158    55..55   248..248        0
MAXCAP, sprites enabled again         7150    55..56   248..248       72
```

**The top split was missing line 55 on about 1% of MAXCAP frames, and sprite
DMA was the cause** — proven by turning `$d015` off while leaving every IRQ,
every batch and every register write in place.

The mechanism: at `YSCROLL = 7`, line 55 is itself a badline and the CPU is
stalled from its cycle 12 to 54. The poll then has only cycles 0..11 to detect
the line and store, and hardware sprites 0..2 are fetched in cycles 57..62 of
the *previous* line, which can push the first sample past 12. The store then
waits out the whole badline and lands around cycle 61 — after every g-access —
so **raster 55 renders from the blank charset: one missing terrain line, one
frame**. Exactly the class of flicker this slice exists to remove.

The fix is in §6 and costs two instructions: at `YSCROLL = 7` the split targets
**line 54** instead. At that phase the first badline of the frame *is* 55, so
lines 48..54 are in idle state and the VIC renders them from `$3fff` whatever
the charset says — splitting on 54 is invisible, 54 is never a badline at that
phase, and the store gains a whole line of slack instead of a dozen cycles.

After the fix, the same three conditions:

```
MAXCAP, sprites enabled               4215    54..55   248..248        0
MAXCAP, same IRQs, sprite DMA OFF     8237    54..55   248..248        0
MAXCAP, sprites enabled again         4206    54..55   248..248        0
RING-SLOW                                     54..55   248..248        0
RING-SHIFT                                    54..55   248..248        0
```

The critical path is now `cpy $d012 / bne (not taken) / sta $d018` — the store
writes on its 4th cycle, 6 cycles after the detecting read, well before the
line's first g-access in cycle 15. **The value is loaded before the poll**; the
first draft loaded it after, which put `jmp`, `ldx` and `lda abs,x` (13 cycles)
in front of the store and measured as landing on raster 56.

One hazard remains and is *not* fixed here, deliberately: a sprite in HW3..HW7
already active at line 55 (`Y <= 54`) would own cycles 0..9 and could still
delay the store by a character or two. No fixture has one — MAXCAP's `Y=50`
entry is in HW2, fetched at the end of line 54 — and the `MIN_SPRITE_Y = 55`
admission rule belongs to the handoff slice, where it removes the possibility
by construction. `edgeLate` is what would catch it meanwhile.

## 11. Pinned YSCROLL 0..7

Sprite bitmaps blanked for this section (a charset clips **characters**; with
the border open nothing clips **sprites** — see §13).

```
    ys=7: 16..54 background | 55..247 175 lit lines | 248..287 background   ok
    ys=6: 16..54 background | 55..247 175 lit lines | 248..287 background   ok
    ys=5: 16..54 background | 55..247 175 lit lines | 248..287 background   ok
    ys=4: 16..54 background | 55..247 175 lit lines | 248..287 background   ok
    ys=3: 16..54 background | 55..247 175 lit lines | 248..287 background   ok
    ys=2: 16..54 background | 55..247 175 lit lines | 248..287 background   ok
    ys=1: 16..54 background | 55..247 175 lit lines | 248..287 background   ok
    ys=0: 16..54 background | 55..247 174 lit lines | 248..287 background   ok
```

Every phase draws terrain on rasters 55..247 **and nowhere else**. No partial
right-hand character line, no leakage above or below.

## 12. Pixel proof of one-pixel motion

With the scroll pinned the world row is frozen, so `ys` and `ys-1` are the same
content exactly one pixel apart. Comparing captures:

```
    ys 7 -> 6: interior rasters 56..245 match at exactly +1 pixel
    ys 6 -> 5: interior rasters 56..245 match at exactly +1 pixel
    ys 5 -> 4: interior rasters 56..245 match at exactly +1 pixel
    ys 4 -> 3: interior rasters 56..245 match at exactly +1 pixel
    ys 3 -> 2: interior rasters 56..245 match at exactly +1 pixel
    ys 2 -> 1: interior rasters 56..245 match at exactly +1 pixel
    ys 1 -> 0: interior rasters 56..245 match at exactly +1 pixel
```

Zero mismatching lines at every step. **This is also the tear test**: a `$d018`
split landing even one cycle late blanks the left of line 55, and that line
could not then match.

The coarse step itself (`ys 0 -> 7`, world row +1, page flip) is not covered by
a pinned capture, because pinning suspends the coarse step by construction. It
is covered structurally instead, and the pieces are all measured: the boundary
is a fixed raster; rows 0 and 24 carry terrain (§14); and `pageWorldLo` predicts
every row of both pages, verified row by row. Raster 55 therefore shows world
row `W` pixel row `7-ys` as `ys` counts 7→0, and at the step `ys` returns to 7
while `W` becomes `W+1` — pixel row 0 of the next world row. One pixel, with no
discontinuity available to it.

**Honest note on what I could not measure.** A consecutive-frame capture under
natural scrolling was attempted and abandoned: at this capture point the
harness returns from `x` on a prompt echo rather than on the actual stop, so
captures duplicated frames and the diff was measuring the harness. The A/B
forensic hit the same trap from the other side. The pinned sweep answers the
same question without it.

## 13. FIX16 / MAXCAP geometry, as actually built

The two reports disagreed; the source and the running schedule say:

```
logical sprites 30, accepted 24, overflow 6, batches 19
accepted Y: 50, 56, 62 ... 188  (step 6)
entry 0: Y=50 -> HW2
```

So **the Fable review's "fixtures start at Y=55" is wrong for MAXCAP** and the
earlier forensic's `Y=50` is right. That matters twice over:

- `Y=50` is above the aperture, and with the vertical border open **nothing
  clips sprites** — so MAXCAP's top sprite row really is visible on rasters
  50..54, outside the terrain. Measured directly: 2 px lit at rasters 52-53, 18
  px at 54. That is a true consequence of the border-HUD architecture, not an
  aperture fault, and it is what `MIN_SPRITE_Y` will address in the handoff
  slice. Do not read it as a regression.
- `Y=50` in **HW2** is why the top split survives at all today: HW0..HW2 are
  fetched at the end of the *previous* line, clear of the poll's window.

`accepted = 24` and `overflow = 6` are unchanged by this slice.

## 14. Rows 0 and 24, and the page letter

```
  ok   matrix row 0 is NOT a blank guard row -- [3, 4, 32, 32, 32, 32]
  ok   matrix row 24 is NOT a blank guard row -- [5, 53, 32, 32, 32, 32]
  ok   column 3 (the old page letter) is blank on every row -- [32]
  ok   every row 0..24 prints the world row pageWorldLo predicts -- bad rows []
```

## 15. Ring smoke

```
  ok   RING-SLOW:  splits 54-55 / 248, edgeLate 0, FEL 250, coherence clean, acc 16
  ok   RING-SHIFT: splits 54-55 / 248, edgeLate 0, FEL 250, coherence clean, acc 16
```

`statAccepted` must be sampled at `mainLoop`: it is cleared at the top of
`buildSchedule` and a ring fixture rebuilds every frame, so a random monitor
stop lands inside that window and reads 0. The first draft of this check
reported that 0 as a failure.

## 16. Timing cost

MAXCAP, handler entry to `exDone`, cycles:

| phase | min | median | max |
|---|---|---|---|
| `exTop` (top split) | 232 | 276 | 332 |
| `exBottom` (border + bottom split) | 338 | 380 | 381 |
| `exFrame` (adopt + batch 0) | 830 | 831 | 894 |
| **structural total (median)** | | **1,487** | |

That is **7.6 % of a PAL frame**, against 6.4 % before this slice
(`exBorder` 410 + `exFrame` 850 = 1,260). **Net cost of the aperture: about
+227 cycles, +1.2 % of a frame.** Most of both splits is a raster poll, and
`exBottom`'s sits in the lower border where nothing else needs the CPU.

`exFrame` got marginally cheaper (850 → 831): it now loads one value from the
frame record instead of masking.

Batch execution is unchanged, checked with the engine's own counter rather than
the monitor's trace log (which truncates under a dense fixture and then
mis-pairs entries — an early draft of this report nearly recorded that noise as
a regression):

```
             batches/frame  frames  executed  expected   ratio   statLate  maxLateRun
boot/fix0         1          7862      7862      7862   1.0000        0        0
MAXCAP           19          3836     72884     72884   1.0000      255       17
```

**Every one of MAXCAP's 19 batches runs on every one of 3,836 frames.**
`maxLateRun` reads 17 where the FIX 16 report measured 12; that is a maximum
over a longer window with every batch still executed and `frameEntryLine`
still 250, not a dropped batch. The chains remain what they always were — 19
batches armed 6 rasters apart, each costing 5-6.

## 17. Regression scope

Targeted suites written for this slice (≈ 6 min total):

- aperture qualification — blank charset, `$3fff`, FIX16 geometry, rows 0/24,
  page letter, pinned sweep, one-pixel steps, ring smoke, invariants;
- split-raster measurement across four fixtures, ~30,000 frames;
- the sprite-DMA discriminator of §10;
- batch-execution count.

`tests/test_p1.py` needed four updates, all forced by the architecture and none
weakening it:

- `HUD_ROWS` and `GUARD_ROWS` are now empty — **all 25 rows are checked**,
  where 8 of 25 used to be skipped. Strictly stronger.
- column 3 must be blank, and `pageWorldLo` must name the displayed page's
  world row — replacing the page-letter check with a stronger one.
- `$d018` has three writers now, all in the renderer; the test asserts the
  count, the three phase labels, and that the splits take their value from the
  frame record rather than from the VIC.
- page-agreement is checked on the **VM bits** (`& 0xf0`), because the low bits
  are the charset and the splits change them twice a frame by design; and
  `exArmFrame` is now `exArmBottom`.

### 17b. Results

**`tests/test_p1.py` — ALL PASS**, 64 checks, exit 0. The scroller suite is the
one that matters for this slice and it now checks all 25 rows, the fixed
aperture's page coherence, `pageWorldLo`, and the three-writer `$d018` rule.

**`make test-fast` — 3 failures, none of them this slice's:**

```
p5_model audit                 clean
gen_p5_tables --check          matches
test_transition.py --quick     ALL PASS
test_p5.py --fast              3 FAILURES
    RING-SLOW:  X=255 crossings match the model  -- engine up 1184 down 416, model 416/416
    RING-FAST:  ZERO publication skips           -- 1 in 5911 frames (0.0%)
    RING-SHIFT: ZERO publication skips           -- 1 in 5856 frames (0.0%)
```

- The two **publication-skip** failures are the standing AMBER from
  `reports/p5-rotating-ring-torture.md` §18, which the previous checkpoint also
  recorded. A skipped frame record is one frame of scroll judder; the sprite
  schedule has no skip path. At 1 in ~5,900 frames they are far below the
  12-15% P5 measured, and there are **two** where the previous checkpoint's
  run had **six** — the diagnostic HUD being off is most of the difference.
- The **X=255** failure did **not** reproduce. Re-run immediately on the same
  binary: `RING-SLOW up 416 down 416, model up 416 down 416`, and all three
  modes exact. It is the documented spurious-crossing-at-placement race from
  the P5 report §8 — `ringPlace` compares each new MSB against `logXHi`, which
  still holds the previous fixture's values, so a retried selection adds
  upward crossings only. That is exactly the shape seen: **up** inflated,
  **down** exact, one mode. Not caused by this slice, and worth a test fix in
  its own right rather than here.

Re-run summary: `test_p5.py --fast` alone → 2 failures, both publication skips.

`make test-full` was not run: the brief rules it out for this slice and nothing
here reaches the P2/P3/P4 executor or builder behaviour it adds over the above.

## 18. Manual test — the point of this slice

```sh
make run          # windowed, normal speed, no warp
```

Press **SPACE** to `FIXTURE 16` (MAXCAP: a diagonal staircase of 24 numerals)
and watch the terrain band behind and around the **top** row of sprites — the
same band that danced before.

1. **Is the ~6.25 Hz dancing/popping gone?** This is the question.
2. **Does the topmost terrain row enter one pixel at a time** at the top edge,
   rather than appearing as a whole row?
3. **Does the bottommost terrain row leave one pixel at a time?**
4. **Any torn horizontal line at the top boundary** — a line where the left
   part is blank and the right part is terrain, or vice versa?
5. **Any torn line at the bottom boundary?**
6. **Are the MAXCAP sprites otherwise unchanged and stable?**
7. **Are RING-SLOW / FAST / SHIFT (R, then SPACE) still visually stable?**

Two things that are expected and are **not** faults:

- **MAXCAP's top sprite row pokes above the terrain**, on rasters 50..54. Its
  first sprite is at `Y=50` and the aperture starts at 55; with the vertical
  border open nothing clips sprites, only characters. Measured, explained in
  §13, and addressed by `MIN_SPRITE_Y` in the handoff slice.
- The terrain's own diagnostic pattern (hex row numbers, bars every fourth
  world row, the walking `*`) is still there. Only the page letter went.

Not declared visually GREEN here. That is yours.

## 19. VICE and disk hygiene

`pgrep -fl x64sc` before: **none**. Every automated launch was `-console` on an
owned port, retained its exact PID and was reaped in `finally` — pids 41754,
41860, 41897, 42008, 42123, 42175, 42280, 42388, 42485, 42544, 42696, 42850,
42887 and the suite runs in §17b (each of which owns and reaps its own).
After: none remaining. No broad `pkill`, no
`open -a`, no window mapped, no keyboard focus taken.

Transient captures and probe scripts lived in `/tmp/6502-engine-slice1` and the
session scratchpad and are deleted.

```
du -sh build/     68K      engine.prg, main.sym, main.vs and nothing else
du -sh .         2.6M      the whole repository
```

Nothing committed. `git status` shows the four source/test files this slice
changed plus the reports.

## 20. What this slice deliberately did NOT do

No HUD. Batch 0 still runs inside the raster-250 frame transaction. No sprite
ownership handoff, no `MIN_SPRITE_Y` / `MAX_SPRITE_Y` admission rule, no change
to logical sprites, the sorter, publication, CURRENT immutability, slot reuse
or admission. `frameEntryLine == 250` on every sample of every run above.

The next slice is the handoff: move batch 0 to a raster-40 phase, add the
sprite-Y bounds (which also closes the last timing hazard in §10), then the HUD.
**Not before the manual test in §18 says this one is right.**
