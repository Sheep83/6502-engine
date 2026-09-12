# Slice 3 — static top-border HUD sprites

**Technical result: six static HUD sprites occupy HW2-HW7 in the open top
border, programmed at raster 4 after the previous frame's Y+256 ghost compare
has gone by, reclaimed in full by the raster-40 handoff, with no ghost anywhere
in the lower vertical blank and the pixel-smooth aperture untouched.**

The HUD is deliberately static. This slice proves ownership and timing; content
is Slice 4.

Not visually GREEN. That is the manual test in §22.

---

## 1. HUD IRQ line: raster 4

Chosen for three independent reasons, all of which hold at 4 and none of which
is about speed:

- **It is after the ghost compare.** Sprite Y is matched against the low byte of
  the raster, so the HUD's Y=16 matches again at raster 272. `exFrame` clears
  `$d015` at raster 250, so that compare passes with nothing enabled; the HUD is
  then programmed and re-enabled at raster 4, on the far side of it. Programming
  the HUD at 250 instead would put a valid Y in place *before* the compare and
  hand the ghost everything it needs.
- **It can never be stalled.** Badlines only exist in rasters 48..247, and
  `$d015` is still zero when the phase runs, so there is no sprite DMA either.
  Measured cost is **434 cycles on every single sample** — not a range, a
  constant.
- **It has room.** The phase ends at raster 10 and the HUD's first sprite fetch
  is for line 17: **six clear rasters**.

Measured entry: **`[4, 4]` on all five fixtures**, ~30,000 frames.

## 2. HUD Y: 16, not the historical 18

The brief said start at 18 and move only on a concrete measurement. Here is the
measurement.

**A VIC sprite at Y=n is displayed on rasters n+1 .. n+21, not n .. n+20.**
Captured and counted at Y=18: the HUD occupied rasters **19..39**, 21 lines,
last line 39 — and the ownership handoff runs at raster **40**. The VIC clears a
sprite's DMA in the line *after* its last, in cycle 16, so at Y=18 the handoff
would be writing sprite registers in the very window where HW3..HW7 can still be
doing a pointer access. No clear line at all between the HUD's last fetch and
the phase that takes its slots away.

```
HUD_Y = 18   ->  displayed rasters 19..39   handoff at 40   0 clear lines
HUD_Y = 16   ->  displayed rasters 17..37   handoff at 40   2 clear lines
```

Y=16 keeps the whole sprite inside the visible region (PAL capture starts at
raster 16), so nothing is lost off the top. Confirmed by capture: **span 17..37,
21 lines**.

## 3. Sprite bitmaps

`$3200-$337f`, six 64-byte blocks, pointers **`$c8`..`$cd`**.

Deliberately disjoint from the gameplay pool (`$2000-$23ff`, pointers
`$80`..`$8f`): the handoff has to overwrite every HUD pointer with a gameplay
one, and if the two pools shared a value a test could not tell a correct
overwrite from a missing one.

The glyphs are the numerals **1 2 3 4 5 6**, drawn by the same generator the
gameplay diagnostic sprites use — a hollow rectangle with a large numeral. The
rectangle makes placement and clipping visible, the numeral makes identity
visible.

`$3200` and not `$3000`: the executor reached `$3005` once the HUD phase was
added and KickAssembler refused the overlap rather than writing code over the
bitmaps. `$3200` leaves the executor 1,536 bytes against the 1,030 it uses.

## 4. Memory-map guards

```asm
.if ((HUD_SPRITES & 63) != 0)                    { .error "HUD block must be 64-byte aligned" }
.if (HUD_SPRITES + 6 * 64 > BLANK_CHARSET)       { .error "HUD block runs into the blank charset" }
.if (HUD_PTR_FIRST >= SPRITE_PTR_FIRST && ...)   { .error "HUD and gameplay pointers overlap" }
.if (hudTablesEnd > $ca00)                       { .error "HUD tables grew into the fixture dispatch" }
.if (* > HUD_SPRITES)                            { .error "executor grew into the HUD bitmaps" }
```

The last one replaces Slice 1's charset guard and is strictly stronger: the
executor now has to clear the bitmaps at `$3200` before it can reach the charset
at `$3800`, and the VIC fetches from both.

## 5-9. HUD register state

| | value | why |
|---|---|---|
| X (HW2..HW7) | 32, 88, 144, 200, 256, 312 | two past 255, so `$d010` is not zero |
| Y (all six) | 16 | §2 |
| `$d010` | **`$c0`** | HW6 and HW7 only |
| `$d015` | **`$fc`** | HW2..HW7 and nothing else — HW0/HW1 stay reserved |
| `$d027-$d02e` | `$01 $07 $0d $03 $0a $0e` | white, yellow, light green, cyan, light red, light blue |
| `$d017` | **`$00`** | see below — the one register the HUD may not touch |
| `$d01b` | **`$fc`** | deliberately dirtied |
| `$d01c` | `$00` | hires, so `$d025/$d026` are unreachable |
| `$d01d` | **`$04`** | HW2 X-expanded — deliberately dirtied |

**`$d017` is the register the HUD may not use.** Y expansion doubles a sprite's
height *and its DMA span*: a Y-expanded HUD at Y=16 would fetch until line 58,
straight through the handoff and into the aperture. It is written to zero
explicitly rather than left alone.

**`$d01b` and `$d01d` are dirtied on purpose.** Gameplay requires both to be
zero, so if the handoff forgot either, gameplay would inherit "behind graphics"
and a double-width sprite. That makes the restoration in §12 a real test rather
than one satisfied by the HUD and gameplay happening to agree.

`$d025/$d026` are not written and that is a rule, not an omission: `$d01c` is
forced to zero at every handoff and every HUD phase, so no sprite on either side
can read them.

## 10-11. Pointer table and the adopted page

`exFrame` patches **both** pointer-writing instructions from the same frame
record, at the same instant it decides `$d018`:

```asm
    lda framePtrHi,x
    sta exPtrStore + 2          // the batch executor's store
    sta huPtrStore + 2          // the HUD's store
```

Two stores, one source, one decision. Neither phase can choose a page and they
cannot disagree about which one was adopted. `PTR_A` and `PTR_B` share the low
byte `$f8`, so a single byte selects the destination.

Verified on the machine at the handoff's entry: all six HUD pointers present in
the **displayed** page, and the non-displayed page's slots 2-7 holding
`$83 $84 $85 $86 $87 $88` — gameplay values from when that page was last live,
untouched by the HUD.

## 12. Handoff restoration proof

Three sampling points, one per stage of the ownership cycle:

```
exHud entry (raster 4)       $d015 == $00                     nothing enabled at all
exHandoff entry (raster 40)  $d015 $fc  $d010 $c0             the HUD owns everything
                             $d01b $fc  $d01d $04             ...including the dirt
                             $d017 $00  $d01c $00
                             all six X/Y, colours, pointers = the HUD's
exTop entry (raster 53)      $d015 = schedEnable              gameplay owns everything
                             $d010 = batchD010[0]             restored from $c0
                             $d017 $00 $d01b $00              the dirt is gone
                             $d01c $00 $d01d $00
                             every HUD pointer overwritten; no $c8-$cd survives
                             every HUD colour and X/Y overwritten by batch 0
```

Every one of those passed. The `$d010` restoration is the sharpest of them: the
HUD leaves `$c0` and gameplay needs `$00`, so a handoff that skipped it would
leave HW6 and HW7 256 pixels adrift.

## 13. Ghosting proof

The chain that makes a ghost impossible, each link measured rather than argued:

1. `exFrame` writes `$d015 = 0` at raster 250.
2. Nothing writes `$d015` again until `exHud` at raster 4 — verified at source
   level (every `$d015` writer is inside the renderer) and on the machine
   (`$d015 == $00` on entry to `exHud`).
3. So across rasters 250..311, which contains the Y+256 compare at **272**,
   there is no enabled sprite to fetch.

Pixel evidence, captured at `exHud` so the framebuffer holds a complete previous
frame:

```
    checked rasters 272..287 (16 of the 21 a ghost would occupy)
  ok   NO HUD ghost anywhere in the lower vertical blank
  ok   rasters 248..287 are entirely background
  ok   no ghost in the lower blank on ANY of 12 consecutive frames
```

The capture covers rasters 16..287, so 272..287 is 16 of the 21 lines a ghost
would occupy — any ghost at all would light some of them.

## 14. Timing

MAXCAP, handler entry to `exDone`:

| raster | phase | n | min | med | max | ends at raster |
|---|---|---|---|---|---|---|
| 4 | `exHud` | 306 | 434 | 434 | 434 | 10.9 |
| 40 | `exHandoff` | 306 | 704 | 712 | 750 | 51.2 .. 51.9 |
| 53 | `exTop` | 306 | 168 | 210 | 258 | — |
| 243 | `exBottom` | 306 | 335 | 378 | 385 | 248.3 .. 249.1 |
| 250 | `exFrame` | 306 | 288 | 289 | 342 | 254.6 .. 255.4 |

`exHud` costs **434 cycles on every sample** — no spread at all, because raster
4 has neither a badline nor sprite DMA.

```
structural phases, median sum   2,023 cycles = 10.29% of a PAL frame
Slice 2 was                     1,642 cycles =  8.35%
the HUD phase adds                381 cycles =  1.94%
```

Clean-run phase rasters, five fixtures, ~30,000 frames:

```
  fixture      frames   HUD enter  HUD exit  handoff enter  handoff exit  top       bottom     late  FEL
  boot/fix0     7606    [4, 4]        10     [40, 40]           51        [54, 55]  [248, 248]    0  250
  MAXCAP        3741    [4, 4]        10     [40, 40]           51        [54, 55]  [248, 248]    0  250
  RING-SLOW     7263    [4, 4]        10     [40, 40]           51        [54, 55]  [248, 248]    0  250
  RING-FAST     3943    [4, 4]        10     [40, 40]           51        [54, 55]  [248, 248]    0  250
  RING-SHIFT    7219    [4, 4]        10     [40, 40]           51        [54, 55]  [248, 248]    0  250
```

**A note on how the entry rasters got that crisp.** `PH_HUD` first measured
`[4, 5]` on every fixture, in a run with no breakpoints anywhere. It was not a
late interrupt: each compare in the dispatch chain costs five cycles before the
handler can read `$d012`, and with interrupt entry (up to 14) plus prologue (19)
a phase far enough down the chain samples its own entry on the *next* line. The
dispatch is now ordered so the two phases whose entry raster is asserted exactly
— handoff and HUD — come first, and the two that open with a raster poll come
last, because a poll absorbs entry jitter by construction. `PH_HUD` then
measures `[4, 4]`.

## 15-16. The two margins

```
HUD phase ends            raster 10   ->  first HUD fetch, line 17      6 rasters
HUD last displayed line   raster 37   ->  handoff, raster 40            2 rasters
handoff ends              raster 51   ->  top split arms, raster 53     2 rasters
handoff ends              raster 51   ->  first legal sprite Y, 55      4 rasters
```

The middle one is the margin this slice had to buy, and §2 is how.

## 17. Aperture regression

Slice 1's aperture is unaffected, re-measured with the HUD live and gameplay
bitmaps blanked:

```
    ys=7..0: HUD 17..37 = 21 lines | 38..54 clear | 55..247 terrain | 248..287 clear
    ys 7->6 ... 1->0: interior rasters 56..245 match at exactly +1 pixel
```

Terrain is still confined to 55..247 in all eight fine-scroll phases, still
steps exactly one pixel per phase with zero mismatching lines, and the sixteen
rasters between the HUD and the aperture stay empty.

## 18. HUD stability and page flips

```
  ok   the HUD band is pixel-identical across 12 frames
  ok   those frames covered at least one page flip
  ok   all six HUD sprites have DISTINCT colours -- 6 distinct of 6
  ok   HW2 really is X-expanded -- 48 columns vs HW3's 24
```

Per-sprite, at the expected positions (image x = C64 sprite X + 8):

```
    HW2 x-expanded  x  40.. 87:  316 lit px, 48 columns, white
    HW3             x  96..119:  230 lit px, 24 columns, yellow
    HW4             x 152..175:  218 lit px, 24 columns, light green
    HW5             x 208..231:  182 lit px, 24 columns, cyan
    HW6             x 264..287:  230 lit px, 24 columns, light red
    HW7             x 320..343:  242 lit px, 24 columns, light blue
```

HW6 and HW7 are the two whose X exceeds 255; both land exactly where `$d010 =
$c0` puts them, which is the same fact the register check makes, seen from the
other side.

## 19. FIX16 / MAXCAP — stress probe only

Per the brief, MAXCAP is not an optimisation target here. It was run to confirm
the HUD introduces no **new** corruption mode, and it does not:

```
MAXCAP   handoff [40,40]  HUD [4,4]  HUD exit 10  handoff exit 51
         top [54,55]  bottom [248,248]  edgeLate 0  frameEntryLine 250
         statPageMismatch 0  statPtrMismatch 0
         publication skips 0 in 436 frames
```

Every ownership check in §12 was run **on MAXCAP** — it is the gameplay load
behind the HUD in that test — so the handoff proof is made against the heaviest
schedule the engine has. Its known heavy-load background flicker is untouched
and unexamined, which is the instruction.

## 20. Regression scope and results

Targeted suites for this slice (~10 min): the three-point ownership proof, the
pixel/ghost proof, the clean-run phase-raster measurement across five fixtures,
the aperture regression, the structural cost trace, and the skip-rate A/B.

```
tests/test_p1.py    ALL PASS   (67 checks)
tests/test_p3.py    ALL PASS   (89 checks)
tests/test_p4.py    ALL PASS   (101 checks, after the two fixes in 20a)
make test-fast      5 FAILURES -- all publication skips, see below
    p5_model audit           clean
    gen_p5_tables --check    matches
    test_transition --quick  ALL PASS
    test_p5.py --fast        5 FAILURES
```

`test_p1` gained a check: the HUD phase has its own deadline — its sprites are
not fetched until line `HUD_Y+1`, so it has `(17-4) x 63 = 819` cycles and uses
**434**.

### 20a. Two test expectations the HUD invalidated

Both in `test_p4`'s `check_presentation_late`, and both are it doing its job:

- **The pointer sanity scan** rejected `$07fc = $ca` as "not a sprite bitmap
  pointer". It was the HUD's HW4 pointer: the scan only knew the gameplay pool
  `$80-$8f`. HW2-HW7 are time-shared now and there are two legitimate pools, so
  the scan accepts `$80-$8f` **or** `$c8-$cd` and nothing else. The exact match
  against CURRENT inside the gameplay span, which is what actually caught the
  original P4 flicker, is untouched.
- **`$d015` now has three owners in a frame**, not two: zero across the blank,
  the HUD mask from ~11 to ~39, the gameplay mask from 55 to 245. The check read
  the expectation from the raster already; it now knows the middle span exists.

### 20b. Ring publication skips — measured properly, and the HUD acquitted

`test_p5 --fast` fails the same five publication-skip assertions it failed in
Slice 2. **Those numbers are saturated lower bounds, not rates** — `publishSkip`
pins at 255, which is the trap the P5 report records twice — so this slice
measured the real rate in windows short enough to avoid it:

```
  fixture      frames   skips    rate
  boot/fix0      488       0     0.00%
  MAXCAP         436       0     0.00%
  RING-SLOW      451      56    12.42%
  RING-FAST      452       0     0.00%
  RING-SHIFT     442      56    12.67%
```

Then the same measurement on a build with **the HUD phase bypassed entirely**
(`exFrame` arms the handoff directly, so `exHud` never runs):

```
  RING-SLOW      465      59    12.69%
  RING-SHIFT     465      58    12.47%
```

**Identical.** The HUD phase's 381 cycles do not move the ring skip rate at all;
the ~12.5% is already there without it. RING-FAST stays at 0% either way, which
is the corroboration — it runs 6-7 batches a frame where RING-SLOW runs 11.

This also corrects my own Slice 2 report, which attributed a rise from "0.01% to
≥4.3%" to that slice's extra interrupt. The 4.3% was a saturated counter and
never was a rate; the true rate then was most likely the same ~12% seen here.
What is certain is that Slice 1 measured RING-SLOW at 1 skip in 9,924 frames
with an unsaturated counter, and it is now ~12.5%, so the rise is real and
happened somewhere in Slice 2 — but **not** in the HUD.

For what it is worth against the production target: this is the frame record
only — one frame of scroll judder, never a sprite — and the rings are 16-sprite
torture fixtures rebuilt every frame. Every fixture at or below the 6-16 sprite
ladder the brief names as representative measures **zero**.

## 21. VICE and disk

`pgrep -fl x64sc` before: none. Every automated launch was `-console` on an
owned port, retained its exact PID and was reaped in `finally`; the suites do
the same and report it themselves. After: none remaining. No broad `pkill`, no
`open -a`, no window mapped, no keyboard focus taken.

Transient captures and probe scripts lived in `/tmp/6502-engine-slice3` and the
session scratchpad.

## 22. Manual test

```sh
make run          # windowed, normal speed, no warp
```

**First, the HUD itself** — it is there on every fixture, so look before
pressing anything. Across the top border you should see six numerals,
**1 2 3 4 5 6**, each a hollow rectangle with a big digit inside:

```
  1 is WHITE and DOUBLE WIDTH   (X-expanded on purpose, to dirty $d01d)
  2 yellow      3 light green      4 cyan      5 light red      6 light blue
```

1. **Are all six there, and rock solid?** No shimmer, no jitter, no
   flicker — they are static and written identically every frame.
2. **Does the HUD flicker at a page flip?** It should not; the flip happens at
   raster 250 and the HUD is programmed at raster 4 through the page the flip
   adopted.
3. **Is there a ghost copy low on the screen**, near the bottom border? There
   must not be. This is the one failure this slice most exists to prevent.
4. **Does any gameplay sprite appear up in the HUD band?** It should not —
   gameplay Y is bounded below at 55.
5. **Do gameplay sprites start cleanly** below the HUD, with no flicker on the
   first row of them?
6. **Is the terrain aperture still pixel-smooth** — top and bottom rows entering
   and leaving one pixel at a time?

Then **R** for `1F` RING-SLOW, SPACE for `20` RING-FAST and `21` RING-SHIFT:

7. **RING-SLOW clean?** Sixteen numerals orbiting, HUD steady above them.
8. **RING-FAST clean?**
9. **RING-SHIFT clean?** Run it a couple of minutes so the orbit sweeps its
   full ±14 rasters under the HUD.

Expect occasional scroll judder on RING-SLOW and RING-SHIFT. It is the ~12.5%
publication skip of §20b, it predates this slice, and the A/B there shows the
HUD does not cause it. The *sprites* must stay perfect through it.

Finally **FIX16 / MAXCAP**, briefly, and only for one question:

10. **Any NEW catastrophic corruption?** Its known heavy-load background
    flicker is accepted and is not what is being asked about.

Not declared visually GREEN here. That is yours, and live HUD content does not
go in until you have given it.
