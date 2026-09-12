# Slice 4 — live HUD framework

**Technical result: the six-sprite top-border HUD now shows live lives, heat,
score and status. All bitmap preparation happens in the main thread inside a
window where the VIC provably cannot be reading, `exHud` costs exactly what it
cost in Slice 3, sprite ownership is still fully restored at raster 40, there is
no Y+256 ghost, and the aperture is untouched.**

Not visually GREEN. That is the manual test in §22.

---

## 1. Logical layout

```
HW2  lives         X  32 (X-expanded, 32..79)   white
HW3  heat, left    X  96 .. 119                 yellow
HW4  heat, right   X 120 .. 143                 yellow
HW5  score, left   X 176 .. 199                 light green
HW6  score, right  X 200 .. 223                 light green
HW7  upgrade       X 280 .. 303                 light red
```

The two halves of each gauge are **adjacent**, so heat reads as one continuous
48-pixel bar (96..143) and the score as six digits in one field (176..223).
Slice 3's spacing was chosen to separate six unrelated numerals and was wrong
for a HUD made of two-sprite objects.

HW7 sits past X=255 so the HUD's `$d010` is not zero: gameplay's is zero on
every static fixture, so a handoff that forgot to rewrite it would leave that
sprite 256 pixels adrift.

## 2. Memory

```
$1400-$17xx   HUD code (main thread only)
$3200-$367f   HUD bitmap pool, 18 blocks of 64, pointers $c8..$d9
                $c8-$cb  heat L/R, score L/R    set 0   } two sets, see below
                $cc-$cf  heat L/R, score L/R    set 1   }
                $d0-$d5  lives 0..5                     precomputed
                $d6-$d9  upgrade 0..3                   precomputed
$c960-$c9fc   HUD state and per-slot placement tables
$cf40-$cfda   digit glyphs and bar-fill patterns
```

**Ten of the fourteen displayed bitmaps are built at assembly time.** Lives has
six possible values and upgrade four, so those two components have no run-time
drawing at all — changing them writes one byte of the pointer table. Only heat
and score are rendered.

Everything outside `$3200-$367f` is above `$4000`, where the VIC never looks.
Nothing shares a byte with the gameplay sprite pool (`$2000-$23ff`), the ring
tables (`$2400-$27ff`), screen page B (`$2800-$2bff`), the raster executor, the
blank charset (`$3800`), the schedule buffers or any runtime state.

## 3. Assembler guards

```asm
.if ((HUD_SPRITES & 63) != 0)                     { .error "HUD block must be 64-byte aligned" }
.if (HUD_SPRITES_END > BLANK_CHARSET)             { .error "HUD bitmaps run into the blank charset" }
.if (HUD_SPRITES < SPRITE_BLOCK + SPRITE_COUNT*64) { .error "HUD bitmaps overlap the gameplay pool" }
.if (HUD_SPRITES < SCREEN_B + $400)               { .error "HUD bitmaps overlap screen page B" }
.if (HUD_PTR_FIRST ... SPRITE_PTR_FIRST ...)      { .error "HUD and gameplay pointers overlap" }
.if (hudStateEnd > $ca00)                         { .error "HUD state grew into the fixture dispatch" }
.if (hudGlyphsEnd > $d000)                        { .error "HUD glyphs ran into the VIC registers" }
.if (hudBitmapsEnd - hudBitmaps != HUD_BLOCKS*64) { .error "HUD bitmaps must be exactly N x 64" }
.if (* > $1800)                                   { .error "HUD code grew into the fixture tables" }
.if (* > HUD_SPRITES)                             { .error "executor grew into the HUD bitmaps" }
```

## 4-7. The four components

**Lives** — `hudLives`, 0..5. Six complete bitmaps built at assembly time from a
four-pixel ship glyph repeated at a five-pixel pitch; five of them end at pixel
23 of 24. The cap is **in the renderer**, not only in the demo that feeds it:

```asm
hudRenderLives:
    lda hudLives
    cmp #HUD_LIVES_MAX + 1
    bcc !ok+
    lda #HUD_LIVES_MAX          // CAP, stated in code
!ok:
    clc
    adc #HUD_PTR_LIVES_0
    sta hudPtrLive + 0
```

**Heat** — `hudHeatLo/Hi`, 0..300, mapped onto 0..48 pixels **with no division
and no loop**: two shifts turn 0..300 into an index 0..75, and one table lookup
turns that into pixels. Saturating at both ends by construction — the index is
clamped before it reaches the table. 300 logical units onto 48 pixels means the
bitmap only changes every sixth unit, and the renderer is only invoked when the
*pixel* count changes, which is what keeps the average cost down.

The bar is drawn by copying one of 25 precomputed three-byte fill patterns into
each of nine rows, per half. A static outline above and below is drawn once at
init, so an empty gauge still shows its extent — otherwise "heat is zero" and
"the HUD is broken" look identical.

**Score** — `hudScore`, six digit bytes, most significant first, fixed width
with leading zeros always drawn. `hudScoreBump` adds one at a given digit and
carries left, at most six iterations, stopping rather than wrapping past the
top digit.

The font is **8 pixels wide on purpose**: a digit is then exactly one byte
column of a sprite, so drawing one is eight loads and eight stores with no
shifting at all. The renderer is fully unrolled straight-line code — identical
cost for 000000 and 999999, and nothing that can loop on data.

**Upgrade** — `hudUpgrade`, 0..3, four precomputed bitmaps showing one to four
filled blocks. Same shape as lives: clamped in the renderer, and the pointer is
the update.

## 8. Dirty flags

One bit per component in `hudDirty`. `hudUpdate` begins:

```asm
    lda hudDirty
    bne !work+
    rts                         // the common case: eleven cycles
```

Measured: **754 frames with a clean HUD produced 0 bitmap rebuilds.**

## 9-10. Update timing, and why the VIC cannot see a partial bitmap

**The VIC reads these bitmaps on rasters 16..37 and nowhere else.** The HUD is
displayed on 17..37; sprite data for display line L is fetched in cycles 0..9 of
line L for HW3..HW7 and in cycles 57..62 of line L-1 for HW2, so the fetch
window is lines 16..37. Outside rasters ~10..51 `$d015` has no HUD bit set at
all, so there is no other opportunity.

`hudUpdate` therefore **refuses to start** unless the raster is inside 56..199:

```asm
    lda $d012
    cmp #HUD_SAFE_LO            // 56: past the handoff (40..51) and top split (53..55)
    bcc hudDefer
    cmp #HUD_SAFE_HI            // 200: fifty rasters before the frame transaction
    bcs hudDefer
```

Readings of 56..199 are unambiguous even though `$d012` is only the low byte,
because the wrapped range 256..311 reads back as 0..55.

**Where it is called from is part of the mechanism.** The once-per-frame block
runs immediately after the frame transaction and reaches this point at about
raster 10 — inside the fetch window, so it would defer every single frame.
`hudUpdate` is called from the main loop's idle **spin** instead, which covers
the rest of the frame; a deferred update finds its slot a few hundred
microseconds later. Measured over 6,137 frames: **2,492 rebuilds, 44,521
deferrals, and every rebuild started between raster 56 and 61.**

The work itself is bounded by construction — every renderer is straight-line or
a counted loop, with no data-dependent iteration. And it is not left as a margin
argument: `hudUpdWrapped` counts any update during which the raster left the
frame, which is the only way one could reach raster 16 of the next frame.

```
  fixture      frames  hudUpdWrapped
  boot/fix0      3412        0
  MAXCAP         6964        0
  RING-SLOW      7113        0
  RING-FAST      7052        0
  RING-SHIFT     7082        0
```

**A note on that counter, because it first said otherwise.** Its initial version
compared `$d012` at the end against `$d012` at the start — but `$d012` is the
**low byte of a nine-bit counter**, so an update that ended at raster 260 reads
back as 4, compares as "less than the start" and scores as a wrap. It reported
twelve false alarms on RING-SHIFT and very nearly bought a double-buffering
redesign that the machine did not need. Bit 7 of a `$d011` *read* is the ninth
raster bit; reading it first is what makes the comparison mean anything.

## 11. Demo mode

Always on, on every fixture, with deliberately different cadences so that a tear
or an ownership mistake cannot hide inside synchronised motion:

```
heat      +/- 2 every frame, ramping 0 -> 300 -> 0     ~3 s each way
score     +10 every 8 frames                           ~1.6 increments a second
lives     one fewer every 128 frames, 5 -> 0 -> 5      ~2.5 s
upgrade   next state every 192 frames, 0 -> 3 -> 0     ~3.8 s
```

Only heat is evaluated every frame, and even heat marks itself dirty only when
the drawn pixel count would change — roughly every third frame.

There are no new controls: SPACE / M / S / R still select fixtures and the HUD
runs live on all of them.

## 12. `exHud` cost: unchanged

```
             Slice 3                  Slice 4
exHud        434 / 434 / 434          434 / 434 / 434     (min / med / max)
exHandoff    704 / 712 / 750          710 / 752 / 764
exFrame      288 / 289 / 342          290 / 291 / 344
```

**Identical, to the cycle, on every sample.** The HUD phase formats nothing,
converts nothing and draws nothing; it points the VIC at bitmaps that are
already finished, so it costs the same whether the score is 000000 or 999990.
That was the design goal of the slice and it is the number that proves it.

## 13. Main-thread update cost

The span `hudUpdWork -> hudUpdEnd` is **elapsed** time and includes every raster
interrupt that preempts the update, so it is measured on two fixtures: boot /
fixture 0 has one sprite batch a frame and is close to the main thread's own
cost, while MAXCAP fires nineteen inside the same window and stretches it. Both
are real and they answer different questions.

| component | fixture 0 (near-pure CPU) | MAXCAP (elapsed) |
|---|---|---|
| clean, nothing dirty | **11 cycles per call** | 11 |
| lives | 97 / 97 / 140 | 102 / 106 / 155 |
| upgrade | 97 / 102 / 145 | 102 / 107 / 150 |
| score | 614 / 624 / 671 | 637 / 641 / 700 |
| heat | 1119 / 1124 / 1178 | 1186 / 1242 / 8102 |
| **all four at once** | **1713 / 1757 / 1760** | 8762 / 8810 / 8858 |

Worst simultaneous rebuild is **1,757 cycles, 8.9 % of a PAL frame**, and it
only happens on a frame where all four values change together — which the demo
cadences (1, 8, 128 and 192 frames) make rare. In the steady state heat fires
about every third frame and score every eighth, so the average is nearer 450
cycles, 2.3 %.

Against the renderer and scroller, which between them use 50-90 % of a frame,
the HUD framework is cheap.

## 14. Handoff proof

Three sampling points, unchanged in method from Slice 3 and re-run against the
live HUD:

```
exHud entry (raster 4)       $d015 == $00                    nothing enabled at all
exHandoff entry (raster 40)  $d015 $fc   $d010 $80           the HUD owns everything
                             $d01b $fc   $d01d $04           ...including the dirt
                             $d017 $00   $d01c $00
                             all six X/Y, colours and pointers are the HUD's,
                             and they match hudPtrLive entry for entry
exTop entry (raster 53)      $d015 = schedEnable             gameplay owns everything
                             $d010 = batchD010[0]            restored from $80
                             $d017/$d01b/$d01c/$d01d = 0     the dirt is gone
                             every HUD pointer overwritten; no $c8-$d9 survives
```

The HUD still deliberately dirties `$d01b` and `$d01d`, which is what keeps the
restoration a real test rather than one satisfied by both sides happening to
agree. `$d017` remains the one register the HUD may not touch: Y expansion
doubles a sprite's DMA span and a Y-expanded HUD at Y=16 would fetch until line
58, through the handoff and into the aperture.

## 15. Ghost proof

Unchanged and re-verified with live content: `$d015` is zero from raster 250
until `exHud` sets it at raster 4, so the Y+256 compare at raster 272 passes
with nothing enabled. Pixel evidence over 14 consecutive frames spanning a page
flip: **no lit pixel anywhere in rasters 248..287.**

## 16. Page flips and pointers

`exFrame` patches both pointer-writing instructions — the batch executor's and
the HUD's — from the same frame record at the same instant it decides `$d018`.
Two stores, one source, one decision. Verified at the handoff's entry: all six
HUD pointers present in the **displayed** page, and the non-displayed page's
slots 2-7 still holding gameplay values (`$83 $84 $85 $86 $87 $88`) untouched by
the HUD. `statPtrMismatch` stayed 0 on every fixture.

## 17. Aperture regression

```
    ys=7..0: HUD 11 lines | 38..54 clear | 55..247 terrain | 248..287 clear
    ys 7->6 ... 1->0: interior rasters 56..245 match at exactly +1 pixel
```

Terrain is still confined to rasters 55..247 in all eight fine-scroll phases and
still steps exactly one pixel per phase with zero mismatching lines. The HUD's
lit content now spans rasters 22..32 rather than the full sprite, because the
live components are vertically centred; the sprite's **DMA** span is still
17..37, fixed by Y alone, which is what the handoff margin is made of.

## 18-19. Fixture results

```
  fixture      frames  HUDenter HUDexit handoff  hoExit  top       bottom      late FEL  wrap
  boot/fix0     3412   [4, 4]      10   [40,40]     51   [54,55]  [248,248]      0  250    0
  MAXCAP        6964   [4, 4]      10   [40,40]     51   [54,55]  [248,248]      0  250    0
  RING-SLOW     7113   [4, 4]      10   [40,40]     51   [54,55]  [248,248]      0  250    0
  RING-FAST     7052   [4, 4]      10   [40,40]     51   [54,55]  [248,248]      0  250    0
  RING-SHIFT    7082   [4, 4]      10   [40,40]     51   [54,55]  [248,248]      0  250    0
```

Every phase exact, aperture exact, page/pointer coherence clean on all five.

**MAXCAP is a stress probe only**, per the brief: it was run to confirm the live
HUD introduces no new corruption mode, and every ownership check in §14 was made
*on MAXCAP*, so the handoff proof is against the heaviest schedule the engine
has. Its known heavy-load background flicker is untouched and unexamined.

**Publication skips**, measured in windows short enough not to saturate the
counter, with the demo live and with `hudDemoTick` stubbed to `rts`:

```
  fixture         HUD demo LIVE        HUD demo FROZEN
  boot/fix0        0.00%                0.00%
  MAXCAP           0.00%                0.00%
  RING-SLOW        3.75% / 5.70%       12.48% / 12.54%
  RING-FAST        0.80% / 5.95%        0.00% / 0.00%
  RING-SHIFT       6.86% / 7.82%       12.45% / 12.51%
```

Read that carefully rather than as a cost. **Fixture 0 and MAXCAP are zero
either way** — on everything at or below the representative load the HUD costs
nothing measurable. On the three 16-sprite ring fixtures the rate stays inside
the same 0-13 % band it occupied before this slice, and the *direction* varies
by mode: RING-SLOW and RING-SHIFT read **lower** with the HUD live, RING-FAST
higher. Adding work cannot reduce skips causally; a publication skip depends on
whether the main-thread pass straddles raster 250, so small changes in pass
length move the beat rather than the load. The honest conclusion is that the
live HUD does not materially change the ring skip rate, and that these numbers
should not be quoted to two decimal places.

## 20. Regression scope and results

Targeted suites for this slice (~15 min): the functional checks below, the
per-component cost measurement on two fixtures, the atomicity instrumentation
over 6,137 frames, the ownership/ghost/page-flip proof, the aperture
regression, and the publication-skip A/B.

```
tests/test_p3.py    ALL PASS   ( 89 checks)
tests/test_p4.py    ALL PASS   (101 checks)
tests/test_p1.py    ALL PASS   ( 67 checks, after the harness fix in 20b)
make test-fast      4 FAILURES -- all publication skips
    p5_model audit           clean
    gen_p5_tables --check    matches
    test_transition --quick  ALL PASS
    test_p5.py --fast        4 FAILURES (RING-SLOW 7.0%, RING-FAST 1.5%,
                                         RING-SHIFT saturated)
```

Functional checks, all passing:

```
  heat 0 -> 0 px      heat 150 -> 24 px      heat 300 -> 48 px
  heat 296/299 -> 47 px   (proportional: only exactly 300 lights the last pixel)
  heat 1000 -> 48 px      (saturates rather than indexing off the table)
  heat 0 leaves the bar completely empty; heat max fills both halves
  all nine bar rows identical at every value
  score 000000 / 123456 / 999999 / 000007 render exactly, six columns each
  lives 0/3/5 select their block; lives 99 clamps to 5
  upgrade 0/2/3 select their block; upgrade 99 clamps to 3
  nothing dirty -> 0 rebuilds over 754 frames; a dirty HUD -> exactly 1
  every dirty flag cleared by the rebuild
  every live HUD pointer inside the pool, none colliding with $80-$8f
```

### 20b. `test_p1`, and a harness bug worth keeping

`test_p1` failed on two counter checks: *both screen matrices were displayed —
A 9931, B **-5683***. A negative frame count is not a renderer fault, so it was
run down before anything else.

Sampling the counters directly on a running machine:

```
   sample   frameCounter  pageA   pageB   A+B   A+B-frames
        5          16625    8313    8312   16625       0
        6          17429    8717       8    8725   56832   <-- MISMATCH
        7          18244    9124    9120   18244       0
```

`pageA + pageB == frameCounter` on nine samples out of ten; one read returned
`pageB = 8` where the machine held 8,716, and the next read was correct again.
**The engine is right and the read was wrong.**

`pageBFrames` lives at `$c26f`, so a sixteen-bit read of it **straddles two
sixteen-byte monitor dump rows** — low byte from one, high byte from the next.
`rd()` validated only the *first* row's address, so a truncated or interleaved
reply produced a value that was wrong rather than short, and the caller could
not tell. It now requires every row to be present, at its own address, and
complete. That is a fix to the shared harness and it benefits every suite;
the P2 histogram wrap, the P5 saturated counter and the nine-bit raster
comparison in §9 are all the same species — a green instrument that was wrong.

With the read fixed, `test_p1` is **ALL PASS, 67 checks**, and the stress run
reports `page A 9931, page B 9933` against 19,864 frames.

## 21. VICE and disk

`pgrep -fl x64sc` before: none. Every automated launch was `-console` on an
owned port, retained its exact PID and was reaped in `finally`; the suites do
the same and report it themselves. After: none remaining. No broad `pkill`, no
`open -a`, no window mapped, no keyboard focus taken.

Transient captures and probe scripts lived in `/tmp/6502-engine-slice4` and the
session scratchpad.

## 22. Manual test

```sh
make run          # windowed, normal speed, no warp
```

The HUD is live on **every** fixture, so look at it before pressing anything.
Across the top border, left to right:

```
  LIVES    white, double-width      up to five small ships
  HEAT     yellow                   a 48-pixel bar with an outline, in two halves
  SCORE    light green              six digits, leading zeros always shown
  UPGRADE  light red                one to four filled blocks
```

What each should be doing:

- **heat** sweeps smoothly from empty to full and back, about three seconds each
  way, moving a pixel at a time. The two halves must behave as **one bar**: the
  right half starts filling only when the left is completely full, and there
  must be no step or gap where they meet.
- **score** counts up by 10 about one and a half times a second. Leading zeros
  stay put — it reads `000120`, never ` 120`.
- **lives** loses one ship about every two and a half seconds, and wraps from
  none back to five.
- **upgrade** adds a block about every four seconds, then resets.

The cadences are deliberately different so that nothing changes in step with
anything else. Watch for:

1. **Torn digits or a torn bar** — half a digit from the old value and half from
   the new, or a bar that is briefly inconsistent between its two halves. This
   is the failure the safe-window design exists to prevent.
2. **Flicker** anywhere in the HUD, especially at the moment a value changes.
3. **A ghost copy low on the screen**, near the bottom border.
4. **Any gameplay sprite in the HUD band**, or any HUD sprite down in the
   playfield.
5. **Flicker on the first row of gameplay sprites** as they appear below the HUD.
6. **The terrain aperture** — top and bottom rows still entering and leaving one
   pixel at a time.

Then **R** for `1F` RING-SLOW, SPACE for `20` RING-FAST and `21` RING-SHIFT:

7. RING-SLOW, RING-FAST and RING-SHIFT clean, HUD steady above them. Expect
   occasional scroll judder on the rings; §19 measures it and it is not caused
   by the HUD.

Finally **FIX16 / MAXCAP**, briefly and for one question only:

8. **Any NEW catastrophic corruption?** Its known heavy-load background flicker
   is accepted and is not what is being asked about.

Not declared visually GREEN here. That is yours, and gameplay integration does
not start until you have given it.
