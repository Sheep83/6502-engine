# Border handoff, playfield aperture, publication fix

**Result: Parts 1 and 2 complete and measured. Part 3 Slice A complete and
measured. Slices B and C are specified but NOT implemented — see §7, which also
explains the architectural decision they depend on.**

Not manually GREEN until you confirm it on screen.

---

## 1. Publication race fix

Already applied during the previous checkpoint and verified in place here
(`src/renderer.asm`, top of `buildSchedule`):

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

The rule it enforces is the one the brief asks for: **before mainline code
starts overwriting NEXT, any pending publication of that same NEXT buffer is
cancelled.** NEXT is then built completely, published only when complete, and
raster 250 remains the only adoption point.

It is deliberately *not* a lock. A flag meaning "a build is in progress",
released only on the normal exit, was tried during the previous task and is
worse: a build abandoned part way leaves it set and the frame IRQ never swaps
again, freezing CURRENT permanently. Withdrawing the publication has no such
state — an abandoned build simply leaves `schedPending` clear and the next
successful build repairs everything.

`schedBuildDefer` reaches 30–255 within a second or two of running, so the rule
is load-bearing rather than dead code.

## 2. Exact cause and location of the visible coarse edge transition

Measured, not guessed. Frames captured below the display window across a coarse
step, then compared line by line over the playfield columns.

Calibration: capture line `y` = raster `y + 15`. With RSEL=0 the display window
is raster 55…246.

```
TOP EDGE                                 pair 0 = the coarse step + page flip
   y  raster |  p0   p1   p2   p3 ...
  39     54  | 0.02 0.90 0.04 0.02        border, static
  40     55  | 0.92 0.35 0.02 0.04   <== WHOLESALE change at the coarse step
  41     56  | 0.24 0.35 0.04 0.02

BOTTOM EDGE
 224    239  | 1.00 0.97 0.16 0.21   <== WHOLESALE change
 225    240  | 0.03 0.97 0.21 0.17
 230    245  | 0.03 1.00 0.97 0.03
 231    246  | 0.00 0.00 0.00 0.00        border, static
```

**The two edges have different causes, and that mattered.**

- **Top, raster 55**: matrix **row 0** — the scroll slack. A 25-row matrix
  displayed through a 24-row window leaves 8 pixels of slack split 4/4 between
  the borders, so rows 0 and 24 are only ever partially visible and *how much*
  depends on the fine scroll. Row 0 changes wholesale on the frame the world row
  advances and the page flips. **This is the coarse seam.**
- **Bottom, rasters 239–245**: these map to matrix **row 23**, which is
  `HUD_ROW_FIX` — the reverse-video `FIXTURE nn SPC=NXT M=3 S=4 R=5` bar. A crop
  of the band confirmed it directly. It changes wholesale on almost every frame
  because **the HUD sits inside the scrolling matrix and rides the fine scroll**,
  wobbling up to 8 pixels. **This is not a coarse seam.** The bottom coarse seam
  proper is matrix row 24, at raster 246 and below, largely already in the
  border.

I had assumed both edges were the same artefact. They are not, and the fix for
each is different.

## 3. Chosen masking technique, and why

**A content mask: matrix rows 0 and 24 are filled with spaces** by a new
`renderGuardRow` in the scroller.

Why not a raster/border trick, which was the first instinct: the vertical border
flip-flop can only be set or cleared by the RSEL comparisons — it closes at
raster 247 with RSEL=0 and 251 with RSEL=1, and there is no way to make it close
at an arbitrary raster. So the border cannot be used to *shrink* the aperture,
only to remove it entirely (§6). `DEN=0` does not close it mid-frame either, and
suppressing badlines part way down the display would corrupt the rows below.

Blank characters cost nothing at run time, cannot destabilise the VIC, and hide
the seam completely whatever content is behind them. They are also exactly the
minimum: the measurement says the artefact is in rows 0 and 24 specifically, so
those are the only two rows masked.

### Measured result

```
AFTER the guard rows                     (same capture and analysis)
 TOP    y40 r55  | 0.00 0.00 0.00 0.32 0.00 0.32 0.00      no wholesale pop
        y47 r62  | 0.00 0.24 0.00 0.32 0.00 0.32 0.00
 BOTTOM y231 r246| 0.00 0.00 0.00 0.00 0.00 0.00 0.00      row 24 seam gone
        y224 r239| 0.00 0.24 0.00 0.97 ...                 row 23 = HUD, remains
```

**Both coarse seams are hidden.** The residual motion at rasters 239–245 is the
HUD bar, which is diagnostic scaffolding rather than playfield, and §7 explains
what removes it.

## 4. Raster lines used

```
raster   0.. 54   vertical border region (now OPEN, see §6) — future HUD phase
raster  55.. 62   TOP GUARD      matrix row 0, blank
raster  63..238   PLAYFIELD APERTURE   matrix rows 1..23 (HUD occupies 1,2,20-23)
raster 239..246   BOTTOM GUARD   matrix row 24, blank
raster 247..311   vertical border region (now OPEN)
```

One character row of guard at each edge — 8 rasters — which is exactly the
scroll slack and no more.

## 5. Chosen HUD border: TOP

Kept as the brief prefers, and nothing measured argues against it. The top
border is where the old shooter proved a sprite HUD stable at Y≈18; sprite Y
wrapping near the bottom border is less attractive; and HUD → gameplay ownership
reads naturally in raster order, with the HUD finishing before the playfield
starts rather than the other way round.

Opening the border to reach it necessarily opens the bottom as well — the
technique removes both closes — so a bottom HUD remains available later without
further raster work.

## 6. Border-opening mechanism

`exBorder`, a new raster phase in `src/renderer.asm`:

```asm
exBorder:
    lda #0
    sta exBorderPending
    lda $d011
    ora #$08            // RSEL=1 before line 247: that close looks for 251
    sta $d011
!wait:
    lda $d012
    cmp #249            // ... and RSEL=0 before line 251: that close looks
    bcc !wait-          //     for 247, which has already gone by
    lda $d011
    and #$f7
    sta $d011
    lda #FRAME_IRQ_LINE
    jmp exArm
```

The flip-flop is made to miss **both** closes, so it never closes and the border
stays open from 247 round to the next frame's open at 55 — which includes the
whole top border.

Both writes are read-modify-write because the low three bits of `$d011` are the
fine scroll, owned by the frame transaction; only bit 3 is touched.

**The timing margin was found by measurement, not assumed.** The first version
armed at 246 and cleared at 248, and the border did **not** open: the two
comparisons happen in *cycle 63* of lines 247 and 251, and one raster line of
margin was not enough against interrupt-entry jitter. Arming at 243 and clearing
at 249 gives four lines before the first comparison and two before the second,
and it opens reliably.

Proof, with `$d020` poked red so an open border is distinguishable from a closed
one (both are black in normal operation):

```
                             before            after
raster  10..40 top border    red  (closed)     BLACK (open)
raster  45..53 above window  red  (closed)     BLACK (open)
raster 250..265 below window red  (closed)     BLACK (open)
```

## 7. HUD → gameplay ownership contract

**Specified here; Slices B and C are NOT implemented.** The reason is a concrete
architectural decision that should be taken deliberately rather than late in a
long session:

> Batch 0 — which programs hardware slots HW2–HW7 for the sprites at the top of
> the playfield — currently runs **inside the frame transaction at raster 250**,
> which is now *inside the opened border*, i.e. inside the HUD phase's raster
> span. A HUD that time-shares HW2–HW7 cannot coexist with that: both want the
> same registers in the same rasters.

So Slice B requires splitting sprite programming out of the frame transaction
and moving it to an explicit handoff raster around line 40–50, leaving the frame
transaction at 250 owning only `$d011`, `$d018`, the pointer destination and
`$d015`. That is a real change to a qualified path and deserves its own
checkpoint, not a tail-end edit.

The contract that split must satisfy:

| register | HUD phase (raster 247…~45) | handoff | gameplay (raster ~50…246) |
|---|---|---|---|
| `$d000-$d00f` X/Y | HUD owns, sets all used slots | **written explicitly** | renderer owns HW2–HW7 |
| `$d010` X MSB | HUD owns, complete value | **written explicitly** | renderer writes complete value per batch |
| `$d015` enable | HUD owns | **written explicitly** | renderer, once per frame |
| `$d017` Y expand | HUD may set | **must be reset** | renderer requires 0 |
| `$d01b` priority | HUD may set | **must be reset** | renderer requires 0 |
| `$d01c` multicolour | HUD may set | **must be reset** | renderer already writes 0 |
| `$d01d` X expand | HUD may set | **must be reset** | renderer requires 0 |
| `$d025/$d026` | HUD only if multicolour used | — | unused by gameplay |
| `$d027-$d02e` colour | HUD owns used slots | **written explicitly** | renderer, per entry |
| pointer table | HUD owns used slots | **written explicitly** | renderer, one patched store |

The rule that makes it safe: **the handoff writes every register whose previous
owner might have changed it, unconditionally.** Nothing may be inherited from
incidental previous-frame state — that class of assumption is what produced the
P4 flicker and the FIX 16 corruption.

HW0/HW1 remain reserved for the future player base/overlay and are untouched by
both phases.

## 8. IRQ phase diagram

As now implemented (Slice A):

```
raster 243   exBorder        open the vertical border, arm 250
raster 250   exFrame         frame transaction: $d011 / $d018 / pointer dest /
                             $d015, adopt CURRENT, then batch 0
raster  Y-12 exBatch         mid-screen mux batches, chained via exLate
             ...
raster 243   exBorder        (next frame)
```

With Slice B the phase between 250 and 55 becomes the HUD phase, and batch 0
moves out of `exFrame` to an explicit handoff raster.

The FIX 16 raster-arm correction is untouched: `exArm` still acknowledges
`$d019` **before** arming and treats an equal target as late.

## 9. Raster timing measurements

MAXCAP, 2,326 handler samples, cycles from interrupt entry to `exDone`:

| phase | min | median | max |
|---|---|---|---|
| border open @243 | 365 | 410 | 417 |
| frame transaction @250 | 849 | 850 | 903 |
| mid-screen batches | 303 | 698 | 1,487 |

The border phase costs about **410 cycles, 2.1% of a PAL frame**, and spends
most of that in a raster poll inside the vertical blank where nothing else needs
the CPU. Its deadline is raster 251 and it finishes by 249 — two lines of
margin, by construction.

The frame transaction is **unchanged** (P5 measured 849–922 for the same
fixture), so the border phase costs it nothing. Mid-screen batch figures are
unchanged; the >756 cases are the documented `exLate` chains, not single-batch
overruns.

## 10. Frame-250 invariant

`frameEntryLine == 250` on every sample, on every fixture tested — boot/fixture
0, MAXCAP, RING-SLOW, RING-SHIFT — with the border phase active. Not moved.

## 11–14. Fixture and coherence results

```
              FEL  pgMis ptrMis scrollLate sortFault  acc
boot/fix 0    250    0     0        0          0       6
MAXCAP        250    0     0        0          0      24
RING-SLOW     250    0     0        0          0      16
RING-SHIFT    250    0     0        0          0      16
```

Page/pointer coherence, back-page regeneration and the scroller are all clean
with the guard rows and the border phase in place. `coarseCount` advances
normally in every case, so scroll wrap and page flip continue to work.

## 15. Scroll-wrap / page-flip

Verified by the edge measurement itself, which spans a coarse step and a page
flip (`(fine 0, coarse 100, page 0) -> (fine 7, coarse 101, page 1)`) and shows
the aperture edges stable across it.

## 16–17. Publication skips and visible judder

Not re-measured here, and deliberately not worked on — the brief rules out
scroller optimisation in this task. The P5 figure stands: roughly 12–15% of
frames defer the **frame record** (fine scroll / page / pointer destination),
which is one frame of scroll hitch, never sprite corruption.

**Whether that is objectionable is now a question a human can actually answer**,
which was the point of masking the seam: previously the coarse pop dominated the
bottom of the screen and made judging scroll smoothness impossible. That
assessment is item 7 of the manual list below, and I am not going to pre-judge
it from a headless capture.

## 18–19. Test runtimes

```
edge measurement (before/after)     ~2 min each
border open/closed discrimination   ~1 min
border cost trace                   ~2 min
invariants across 4 fixtures        ~3 min
test_p1 (scroller regression)       ALL PASS, ~11 min
```

```
make test-fast                      13m50s

  p5_model audit                    clean
  gen_p5_tables --check             matches
  test_transition.py --quick        ALL PASS
  test_p5.py --fast                 6 FAILURES
```

The six P5 failures are the **known pre-existing publication-skip AMBER** from
`reports/p5-rotating-ring-torture.md` §18 — the same six lines, three modes x
(counter saturated, non-zero skips). They predate this work and are untouched by
it. **Nothing regressed.**

### Was the full suite necessary?

Not run, and I do not think it is warranted. The production changes are: six
instructions at the top of `buildSchedule` (already qualified last checkpoint), a
blank-row renderer in the scroller, a relocation of two lookup tables, and one
new raster phase in the vertical blank. The behaviour those could break is the
scroller and the frame/raster path, and both were exercised directly —
`test_p1` ALL PASS covers row content, page identity and pointer coherence over
a long scrolling run, and the transition suite covers MAXCAP activation, page
and pointer destination, and `frameEntryLine == 250`.

The remaining full-suite coverage is P2/P3/P4 executor and builder behaviour that
none of these changes reach. I would run `make test-full` once before the next
checkpoint is declared rather than spend the hours here — say so if you want it
now.

## 20. Manual test instructions

`make run`, windowed, normal speed. SPACE cycles; **M**/**S**/**R** jump to the
first P3/P4/P5 fixture.

1. **Is the coarse top/bottom pop gone?** Watch the very top and very bottom of
   the scrolling area for several seconds. There should be no sudden wholesale
   change of the edge row when the world steps.
2. **Does the central playfield look genuinely smooth now?**
3. **Is the border region stable?** It is open but empty, so it should be plain
   black with no flicker, tearing or stray pixels.
4. **Any flicker at the top of the screen**, around where the border meets the
   display?
5. **`16`, `1F`, `20`, `21` still visually correct?** MAXCAP's 24 numerals,
   the ring's 16.
6. **Any corruption over repeated page flips?** Leave it running a minute or two.
7. **Now that the edge pop is gone, are there visible one-frame scroll
   hitches?** This is the one I most want your answer on — it decides whether
   the publication-skip rate needs work next.

Also note: the HUD bar at the bottom still wobbles with the fine scroll. That is
expected and explained in §2 — it is the HUD riding inside the scrolling matrix,
not a scroll fault. Removing it is what Slice B/C buy.

## 21. VICE and process hygiene

`pgrep -fl x64sc` before: none. Every launch retained its exact PID and was
reaped in `finally`; `-console` throughout, no window mapped, no focus taken; no
broad `pkill`, no `open -a`. Transient captures in the session scratchpad.

## 22. Disk usage

```
du -sh build/     68K
du -sh .         2.5M
```
