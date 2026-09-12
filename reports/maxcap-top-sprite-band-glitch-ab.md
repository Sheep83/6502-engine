# MAXCAP top sprite-band background glitch — A/B diagnosis

**Result: the emulated C64 framebuffer contains no terrain corruption at all.**
Sprite DMA, mid-screen IRQ execution, `exLate` chaining and badline alignment
are each ruled out by direct experiment. The only real frame-to-frame
discontinuity anywhere in the picture is **8 raster lines at the top of the
aperture (rasters 56-63), once every eight frames**, and it sits inside the band
the top row of MAXCAP sprites occupies.

That discontinuity is the blank guard row, not a renderer fault. **No production
fix applied** — the brief rules the aperture out of this task, and the
measurement says there is nothing else to fix.

Nothing in `src/` was modified. Every experiment was a monitor poke on a running
machine.

---

## 1. Suspect batch and geometry (verified, not assumed)

MAXCAP = fixture 22, display ID `16`: 30 logical sprites at `Y = 50 + 6i`, X
cycling through seven columns (30, 60 … 210), **24 accepted, 6 overflow**,
19 batches.

```
entry  Y   X  slot  displayed rasters   programmed by
  0   50  30   2      50.. 70          batch 0 @ raster 250
  1   56  60   3      56.. 76          batch 0 @ raster 250
  2   62  90   4      62.. 82          batch 0 @ raster 250
  3   68 120   5      68.. 88          batch 0 @ raster 250
  4   74 150   6      74.. 94          batch 0 @ raster 250
  5   80 180   7      80..100          batch 0 @ raster 250
  6   86 210   2      86..106          batch 1 @ raster 74
  7   92  30   3      92..112          batch 2 @ raster 80
  8   98  60   4      98..118          batch 3 @ raster 86
batch lines: 250, 74, 80, 86, 92, 98, 104 … 176   (six rasters apart)
```

**The "top row of sprites" is entries 0-6 — the first diagonal — occupying
rasters 50 to 106.** That is the band under investigation.

An early run of this probe read the schedule before the publication had been
adopted and measured the *previous* fixture (6 entries, 1 batch). Every
subsequent run therefore free-runs and verifies `schedEntries == 24`,
`schedBatches == 19` and `schedY[0] == 50` in the CURRENT buffer before
measuring anything.

## 2. Badline relationship and handler behaviour

Handler entry rasters and cost, 2,317 traced samples on MAXCAP:

```
raster  74: n= 226  cost  312/ 357/ 373 -> ends raster  79.0.. 79.9
raster  80: n= 222  cost  312/ 696/1093 -> ends raster  85.0.. 97.3
raster  86: n=  87  cost 1095/1109/1476 -> ends raster 103.4..109.4
raster  92: n=  37  cost 1090/1452/1459 -> ends raster 109.3..115.2
raster  98: n=  28  cost  745/ 745/1442 -> ends raster 109.8..120.9
   …
raster 243: n= 229  cost  365/ 410/ 417  (border phase)
raster 250: n= 229  cost  849/ 850/ 913  (frame transaction)
statLate = 255 (saturated)   maxLateRun = 12   frameEntryLine = 250
```

Batches are armed 6 rasters apart and a batch costs 5-6; handlers therefore
chain constantly. **A handler entered at raster 86 can still be running at
raster 109** — 23 raster lines, inside the visible display, straight through the
suspect band, with three or four batches executed back to back. Badlines fall
on `raster & 7 == YSCROLL`, so under natural scrolling every batch passes
through all eight badline relationships every eight frames.

This is the worst-looking thing in the diagnostics and it corrupts nothing
(§3-§7).

## 3. Is the emulated framebuffer wrong? — static-screen control

`pinFine` holds the fine scroll, which also suspends the coarse step, the page
flip and back-page regeneration. With a static fixture the picture is then
completely static, so consecutive frames **must** be pixel-identical. Full
sprite bitmaps, all 19 batches, all eight badline phases:

```
pinFine=0 ($d011=$10): 4 frames IDENTICAL (384x272)
pinFine=1 ($d011=$11): 4 frames IDENTICAL
pinFine=2 ($d011=$12): 4 frames IDENTICAL
pinFine=3 ($d011=$13): 4 frames IDENTICAL
pinFine=4 ($d011=$14): 4 frames IDENTICAL
pinFine=5/6/7        : 1-3 lines at image y 227-229 only
```

Image `y = raster - 16` (calibrated below), so y 227-229 is raster 243-245 —
**the capture point itself**, where the screenshot tears against the previous
frame. Every other line is identical in every phase.

So the VIC, under the full IRQ chain and full sprite DMA, draws a stable
picture. Whatever the human sees needs scrolling.

## 4-7. The A/B matrix

All four conditions scroll naturally with the sprite **bitmaps blanked to
transparent**. Blanking changes nothing about DMA, batch timing, register
writes or IRQ schedule — a transparent sprite is fetched and steals exactly the
same cycles — but it removes the sprite pixels, so the frame is pure terrain and
a scroll-compensated diff becomes meaningful: the playfield moves up exactly one
pixel per frame, coarse step included, so line *y* of frame *n* must equal line
*y-1* of frame *n+1*.

**The comparison shift is measured per pair, not assumed.** The remote monitor
occasionally drops an `x`, which skips a frame; the picture has then moved two
pixels and a fixed +1 comparison calls the whole screen corrupt. A first pass of
this matrix did exactly that and reported 177-183 "bad lines" per ordinary frame
in the `full` condition. Re-running with the shift measured against the
machine's own `frameCounter` delta showed every one of those pairs is **clean**.
That false result is recorded because it is the same class of error the P2
histogram wrap and the P5 saturated counter were.

```
                  DMA   mid-screen IRQ   ordinary pairs      page-flip pair
full              yes   yes (19 batches)  0 residual (x11)   ~96 lines
noDMA  $d015=0    NO    yes (19 batches)  0 residual (x11)   ~95 lines
noIRQ  batches=1  yes   NO                0 residual (x11)   ~95 lines
neither           NO    NO                0 residual (x11)   ~96 lines
```

`full` ran with `statLate` saturated and `maxLateRun = 12`, and every ordinary
frame was still **pixel-exact**.

- **(3) transparent bitmaps:** terrain unaffected — the glitch is not sprite
  pixel content.
- **(4) solid bitmaps:** not run. Made redundant — with the bitmaps blanked the
  terrain is already provably perfect, and a sprite cannot alter a character
  fetch (§8).
- **(5) sprites disabled, IRQ present (`noDMA`):** clean.
- **(6) sprites present, IRQ suppressed (`noIRQ`):** clean.
- **(7) vertical shift / badline:** covered more completely by the eight-phase
  `pinFine` sweep in §3 and by the fact that natural scrolling moves every batch
  through all eight badline phases every eight frames. No phase-dependent fault
  appeared in any condition.

**Every condition, including "no DMA and no mid-screen IRQ", shows the same
~95-line difference on the page-flip frame and nothing else.** The sprite
machinery is not involved in any way.

## 8. What the page-flip difference actually is

The differing rasters have a fingerprint: they are exactly those with
`raster mod 8 ∈ {0,1,3,6}`, repeating identically down the whole screen — a
*character glyph* difference, not corruption. Two things legitimately change at
a flip:

1. **Column 3 of every row is the page letter**, `A` or `B` (`renderBackgroundRow`
   writes `regenPage + 1` at offset 3). It must change on all 23 rows at once.
2. **The aperture guard rows.** Matrix rows 0 and 24 are blank, so the world row
   hidden inside a guard row before the flip is revealed after it.

Masking those two out:

```
                       differing   minus page-letter   minus guard-row edge
neither  flip 1->2        96             8                    0
noIRQ    flip 6->7        95             7                    0
noDMA    flip 3->4        95             7                    0
```

**Residual zero.** The edge rasters are `56..63` in every case.

Screen memory confirms the geometry independently: the incoming page's matrix
row *r* carries exactly the world row the outgoing page carried at row *r+1*,
for every row, so the flip is a correct one-pixel step. (Reading the outgoing
page *after* the flip shows its rows 0-4 already rewritten with the next cycle's
world rows — that is the back-page regeneration doing its job, not damage.)

## 9. VIC / page / pointer state

```
$d011 $10..$17 (DEN=1 RSEL=0, YSCROLL counting 7..0)   $d016 $c8   $d01d $00
$d018 $15 (page A, char base $1000) / $a5 (page B, same char base)
$d015 $fc    $d010 $00 (every MAXCAP X < 256)
frameEntryLine = 250 on every sample       publishSkip  = 0
statPageMismatch = 0   statPtrMismatch = 0  scrollLate   = 0
```

The only CPU writes into a screen matrix during display are `exPtrStore`'s
sprite-pointer byte at `$07F8+slot` / `$2BF8+slot` — past the 40th column of row
24, never fetched as a character — and `regenTick`, which writes the **back**
page (page coherence measured clean, and `publishSkip = 0` on MAXCAP over
9,494 frames in a prior run, so the one path that could aim regeneration at the
displayed page never fires here).

## 10. Root cause

**Demonstrated:** there is no background corruption. The mechanism a corruption
would need — a change to `$d011`/`$d016`/`$d018`/`$d021`/colour RAM inside the
display, a write to the displayed matrix before its row's badline, or a badline
moved to an abnormal cycle — does not occur. Sprite DMA delays the CPU, which is
normal and cannot alter what the VIC fetches for characters; the A/B matrix
confirms it empirically.

**The only real artefact in the band, and the only candidate for what the human
sees:** with the vertical border open and matrix rows 0/24 blanked, the top of
the terrain sits at raster `56 + YSCROLL`. As YSCROLL counts 7→0 the terrain's
top edge climbs 7 pixels over 7 frames; at the coarse step YSCROLL wraps 0→7,
the edge drops back 8 pixels and the world row advances. The top terrain row
therefore **pops in and out by a whole character row 6.25 times a second**,
at rasters 56-63 — inside the band the top sprite row (rasters 50-106) occupies,
which is why it reads as "the band behind the top sprites".

This is exactly Manual Observation 3 of the previous task and §4.2 of
`reports/fable-vic2-aperture-sprite-band-review.md`. It is an aperture design
artefact, and the brief rules the aperture out of this task.

A second, smaller real artefact: the **page-letter column** (character column 3,
C64 X 24-31) changes `A`↔`B` on all 23 rows simultaneously every eight frames.
That is the scroller's own diagnostic and will disappear with the diagnostic
terrain.

## 11. Production fix

**None applied.** The demonstrated cause is the guard-row aperture, which this
task is explicitly told not to touch, and nothing else was found to fix.

## 12. What remains unknown

- **Host presentation was not separately tested**, and no longer needs to be to
  make progress: the emulated framebuffer is now *proven* stable on ordinary
  frames. If the user sees disturbance that is **not** in the 6.25 Hz rhythm of
  the coarse step, it cannot be coming from the emulated C64 and the next
  suspect is VICE's own rendering (vsync, window scaling, host refresh).
- **Real hardware** — all of this is VICE. The guard-row pop is geometry and
  will be identical; the absence of corruption under a 23-raster IRQ chain is an
  emulator statement, not a hardware one.
- Whether the top-band pop is genuinely what the human is calling "the glitch"
  is for the human to say; it is the only candidate left in the emulated output,
  and it is in the right place.
- All measurement was under warp, which changes wall-clock only.

## 13. Manual verification — one test

```sh
make run          # windowed, normal speed
```

Press **SPACE** to `FIXTURE 16` (MAXCAP, 24 numerals in a diagonal staircase).
Watch the terrain in the band behind and around the **top** row of sprites.

Nothing was changed, so nothing will look different. The question is only what
you are seeing:

- **Does the disturbance happen in a regular rhythm, a bit over six times a
  second, right at the very top edge of the terrain — the topmost terrain row
  appearing and disappearing as a whole row rather than sliding in a pixel at a
  time?** Then it is the guard-row aperture pop, it is fully explained, and the
  fix is the pixel-smooth aperture work (Fable review §4.4), not a renderer fix.
- **Is there also an 8-pixel-wide vertical stripe near the left edge flickering
  between two letters at the same rhythm?** That is the page-letter diagnostic
  column, by design.
- **Is it irregular, or anywhere other than the top edge?** Then it is not in the
  emulated frame at all — every other line of every ordinary frame is provably
  pixel-identical to a perfect one-pixel scroll — and the next suspect is VICE's
  host rendering.

Not declared visually GREEN here. That remains yours.

## 14. Runtime, VICE and disk

Eight automated runs, about 25 minutes total. No qualification suite was run;
no production code changed, so none was warranted.

`pgrep -fl x64sc` before: **none**. Every launch was `-console` on an owned
port, retained its exact PID and was reaped in `finally` — pids 38443, 38496,
38545, 38599, 38683/38720, 38814, 38897, 39006/39045, 39132, 38528. After:
none remaining. No broad `pkill`, no `open -a`, no window mapped, no focus
taken.

147 screenshots (1.3 MB) and every probe script lived in `/tmp` and the session
scratchpad and are deleted.

```
du -sh build/     68K
du -sh .         2.5M
```

`git status` unchanged from the start of the task: no file under `src/` or
`tests/` was modified. Not committed.
