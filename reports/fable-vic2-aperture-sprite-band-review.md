# Independent review — VIC-II sprite-band background glitch and the pixel-smooth vertical aperture

Adversarial architecture/timing review. Source inspected directly
(`src/renderer.asm`, `src/scroll.asm`, `src/main.asm`, `src/fixtures.asm`,
`src/p3_fixtures.asm`), the five reports read, one targeted measurement taken
(§1.2). Nothing modified. Nothing committed.

**Headline findings**

1. The MAXCAP top-band glitch has **no mechanism in the current IRQ/VIC path**
   that I can find by inspection: nothing in the executor writes a register or
   a memory location that changes what the VIC fetches for characters. The one
   code path that *can* write the displayed matrix needs a publication skip,
   and MAXCAP produced **0 skips in 9,494 frames**. Evidence is insufficient
   to name a root cause; §3 gives a five-run A/B matrix that will.
2. The "pop" at the aperture edges is **self-inflicted**. The vertical border
   flip-flop at rasters 55/247 is the VIC-II's only free, pixel-exact vertical
   clipper — for characters *and* for sprites — and the border-opening phase
   removed it. The guard rows then hid the coarse seam by turning it into a
   whole-row pop. The previous report's "the border cannot shrink the aperture"
   was true and irrelevant: it never needed to shrink; it needed to be left
   alone.
3. A top-border sprite HUD and hardware edge clipping are **mutually exclusive
   on the VIC-II** (§4.2 proves it from the flip-flop rules). The mandate should
   be re-examined with that cost in front of it: it forces *two* seven-sprite
   mask bands, culling of every gameplay sprite at both edges, and four sprite
   ownership phases per frame. The boring alternative — border closed, HUD as
   two fixed character rows at the top, one YSCROLL split, one seven-sprite mask
   band — gives pixel-perfect edges, sprite exit through the bottom edge for
   free, and ~4% of the frame. §4–§6.
4. The 12–15% publication-skip figure that has been carried since P5 is
   **stale**: with the diagnostic HUD off, RING-SLOW skipped once in 9,924
   frames. Stop planning around it (§9).

---

## 1. MAXCAP top-band glitch — candidates, ranked

Fixture geometry first, because two of the candidates depend on it. MAXCAP is
30 static sprites at `Y = 50 + 6i`, X cycling through seven columns
(30, 60, …, 210), 24 accepted (`Y` 50…188), batch 0 = entries 0–5 (`Y`
50…80) programmed at raster 250, then nineteen one-entry batches at lines
74, 80, …, 176. Every sprite is a hollow rectangle with a numeral. The
"top row" the user describes is the first diagonal of the staircase — six
sprites whose display spans rasters **51…101**, overlapping three-to-four deep.

Two facts the candidates must respect:

- The character playfield in that band is matrix rows 0–6 (rasters 48+ys …
  103+ys). Nothing in the executor writes rows. The only writers of any
  screen matrix are `renderRow`/`renderGuardRow` (back page, main thread) and,
  when `HUD_VISIBLE` is true, `hudTick` (displayed page, rows 1, 2, 20–23).
- The only VIC registers the executor touches are `$d000–$d010`, `$d015`,
  `$d01c`, `$d027–$d02e`, `$d011`, `$d018`, `$d012`, `$d019`. Of these only
  `$d011` and `$d018` can alter character fetches, and both are written at
  raster 250 (and `$d011` bit 3 at 243/249), all in the lower border.

### 1.1 Ranked

| # | candidate | mechanism required | fits "band = top sprite row"? | status |
|---|---|---|---|---|
| **1** | **Observation predates the HUD removal.** Rows 1–2 were white, reverse-video diagnostic text at rasters 56+ys…71+ys — *inside* the top-sprite band — updated every sixth frame and riding the fine scroll | none needed; that *is* what it looks like | exactly | **must be excluded first**: re-observe on the `HUD_VISIBLE=false` build |
| **2** | **Perceptual**: 3–4 hollow sprites stacked in the band, terrain bars (every 4th row, 32 px period) scrolling *through* their interiors at 1 px/frame, high-contrast outlines chopping the bars | none; hardware behaving | plausible — density is uniform 50…208 but the *top* of the staircase is where the eye lands first and where four outlines overlap before the pattern is "read" | discriminate with run C (§3): solid sprites, same geometry |
| **3** | **Host-side tearing/judder** (VICE GTK3 renderer, 50 Hz emulated on a ≠50 Hz host, vsync state) | none in the C64; a band where two emulated frames meet on the host scanout | a host tear sits at a fixed *screen* position, which could coincide with the band | run E: monitor `screenshot` sequence vs. eye; toggle VICE vsync/fullscreen; move the window |
| 4 | **Regeneration writes the displayed page** after a coarse-step publication skip (see mechanism below) | real, and it hits **rows 0–4 = rasters 48…88+ys**, the top band, for one frame | very well — *if* skips occur | **measured: MAXCAP 0 skips / 9,494 frames** → not live here; still a latent design fault, §8 |
| 5 | IRQ timing: chained `exLate`, batch on a badline, sprite DMA + badline cycle pressure | can only delay a *sprite* register write; cannot change a character fetch | no | reject as a background mechanism; the sprite layer was pixel-verified in the FIX 16 forensic |
| 6 | `$d011`/`$d018`/pointer writes at a dangerous raster | would need `frameEntryLine ≠ 250` | no | `frameEntryLine == 250` on every sample here and in every prior report |
| 7 | Idle-state graphics in the open border (`$3fff`) | static; would show as a constant pattern above 48+ys, not a transient | no | `$3fff = $00` in VICE (measured); **unknown on hardware** — write it, §8 |

### 1.2 The one real code-level mechanism (candidate 4), and why it is not this bug

`scrollTick` at a coarse step flips `dispPage` in software, points `regenPage`
at the page that is **still being displayed**, resets `regenRow`, then calls
`publishFrame`. If `framePending` is still set from the previous frame the
publication is *dropped* (`publishSkip`), the IRQ at 250 adopts the **old**
record (old page), and on the next main-loop pass `regenTick` writes rows 0–4
of the page the VIC is displaying, with world rows two ahead of what the rest of
the page shows. One frame later the next `scrollTick` publishes the flip and it
heals. Rows 0–4 are rasters 48+ys … 88+ys: a one-frame corruption in exactly
the band described, once per (skip ∧ coarse step).

Measured this session (warp, one owned `x64sc`, counters zeroed after fixture
selection):

```
MAXCAP     9,494 frames   1,187 coarse steps   publishSkip 0   scrollLate 0
RING-SLOW  9,924 frames   1,241 coarse steps   publishSkip 1   scrollLate 0
```

So on the fixture where the glitch was seen this path never runs. It remains a
design hazard — the main thread decides which page is "back" before the IRQ has
agreed — and §8 asks for it to be closed regardless.

### 1.3 What I could not find

I looked specifically for: a `$d016` write (none after boot), a `$d021`/colour
RAM write after init (none), any main-thread write to `curPage`'s matrix (only
the path above), a write to `$3fff`'s neighbourhood (none), a raster-arm that
could land the frame transaction mid-screen (the FIX 16 fix holds), and any
executor path that writes screen RAM other than the eight pointer bytes at
`$xxf8` (none). **The static picture is clean.** If the glitch survives run A
of §3, it is either perceptual (run C) or environmental (run E), and if it
survives those too, then it is something a capture must show — at which point
the pixel-diff harness from the FIX 16 forensic, pointed at rows 0–6 rather than
at sprites, is the next tool.

## 2. Mechanism each candidate would need — the causal path, stated

- **CPU delay by VIC DMA** (badlines, sprite fetches) changes *when* the 6502
  executes; it can make a sprite register write late (a sprite fault) or an
  IRQ handler overrun (a scheduling fault). It can never change the bytes the
  VIC fetches for characters. Any candidate that ends at "…so the CPU was
  delayed" is not a background-corruption mechanism.
- **Visible character corruption** requires one of: a change to `$d011`
  (YSCROLL/RSEL/DEN/BMM/ECM), `$d016`, `$d018`, `$d021–$d024` or colour RAM
  at a raster inside the display; a write to the displayed matrix at or before
  its row's badline; or a badline condition appearing at a cycle other than
  the normal one (a late `$d011` write — the VSP family). Only the second
  exists in this program (candidate 4), and only under a skip.

## 3. Fastest discriminating experiments

Five short windowed runs, ≤30 s each, all on MAXCAP. Each removes one
variable while holding the rest.

| run | change | isolates |
|---|---|---|
| **A** | current build, `HUD_VISIBLE=false`, re-observe | candidate 1 (observation era). If clean, stop. |
| **B** | `fixtureYOffset` +16 and +40 (moves the whole staircase down; badline phase and top-band membership both change) | whether the effect follows the *sprites* or stays at the *raster band* |
| **C** | temporarily point every `logPtr` at one solid `$ff` bitmap (same X/Y/slots/batches) | candidate 2 (perception of scrolling bars through hollow outlines) |
| **D** | `pinFine=1` (scroll frozen, batches identical) | whether scrolling is necessary for the effect |
| **E** | `x64sc` monitor `screenshot` × 60 consecutive frames, diff rows 0–6 frame-to-frame with the scroll compensated (compare line *y* of frame *n* with line *y−1* of frame *n+1*, not the same *y*) | candidate 3 (host) vs. a real emulated-frame difference. A host tear never appears in a monitor screenshot |

Cheap instrumentation to add before B–E, all off the critical path:
`$d020` flashed for the duration of each mid-screen handler (already the
classic border-marker), and a saturating counter incremented by `regenTick`
whenever `regenPage == curPage` — that single byte proves or kills candidate 4
permanently and costs two instructions.

Not proposed: a soak. Nothing here needs more than one minute of observation.

## 4. Pixel-smooth vertical aperture — what the VIC-II can and cannot do

### 4.1 The rules (Bauer §3.9, verified against the current behaviour)

The vertical border flip-flop is **set** only when the raster reaches the
bottom comparison line in cycle 63 — **247** (RSEL=0) or **251** (RSEL=1). It
is **reset** only when the raster reaches the top comparison line in cycle 63
with DEN set — **55** (RSEL=0) or **51** (RSEL=1). There are no other set or
reset conditions. Consequences:

- The border **cannot** be set anywhere in 252…54 and cannot be reset anywhere
  in 56…246. This is what the previous report found, and it is correct.
- Therefore the state during the whole top border 252…54 is the state left at
  251. Making the flip-flop miss both closes (the current trick) opens *both*
  borders. You cannot open the bottom only, or the top only.
- Between 55 and 246 the border is a pixel-exact clip of **everything** —
  characters *and sprites*. A sprite at Y=40 shows only its rows below raster
  55; a sprite leaving through 247 is cut cleanly. This is the property the
  scroller needs and the property the border-open phase discarded.

### 4.2 Why the current presentation pops

With RSEL=0 and a closed border, matrix row 0 spans 48+ys…55+ys and is clipped
at 55; as `ys` counts 7→0 the visible part shrinks 8→1 lines, then the coarse
step advances the world row and `ys` returns to 7 — content moves up exactly
one pixel. **That is already pixel-smooth. It is what 24-row mode exists for.**
The "wholesale change at raster 55" in `border-handoff-scroll-mask.md` §2 is a
fixed-raster diff across a scroll: line 55 legitimately goes from pixel row 7
of world row W to pixel row 0 of W+1, and with bars every fourth row that
diff is large. It was not a pop. The bottom "pop" measured at 239–245 was the
HUD, as that report itself found.

Now open the border: rows 0 and 24 are fully visible at 48+ys and 240+ys; their
top/bottom edges sawtooth by 8 px. Blank them (guard rows) and the sawtooth
moves to rows 1 and 23: the terrain's top edge sits at 56+ys, climbs 7 px over
7 frames, then a whole row vanishes and the next appears 8 px lower. That is
the observed pop, at both ends, and it is inherent to "open border + blank
guard rows". No content trick removes it.

### 4.3 The only two pixel-exact vertical clippers

1. **The vertical border**, at 55/247 (RSEL=0) or 51/251 (RSEL=1). Free. Also
   clips sprites.
2. **Opaque sprites in front of the graphics.** 7 X-expanded sprites (48 px)
   cover 336 px ≥ 320; 6 cover 288 and are not enough even for 38 columns
   (304). A mask band therefore costs 7 hardware sprites for the lines it
   covers, and those slots for the 21 DMA lines of the sprite, transparent
   rows included.

There is no third. In particular, a YSCROLL split does not clip: the first row
after the split starts at pixel line 0 and the 0–7 line gap above it *pumps*
with the scroll phase — the same pop in a different place. DEN=0 mid-frame
does nothing to the border. FLD delays the first badline but cannot show a
partial row. VSP is excluded by the brief and would not help.

### 4.4 Recommended architecture

**Close the border. Let the hardware clip. Put the HUD at the top of the
display as two fixed character rows, split YSCROLL beneath them, and mask the
split's pump band with one row of seven opaque sprites.**

```
raster  48+7=55  HUD row 0     matrix row 0, YSCROLL=7, border-clipped above
raster  63       HUD row 1     matrix row 1
raster  65       IRQ: park YSCROLL          (see 4.5)
raster  71       IRQ: YSCROLL = scroll      (see 4.5)
raster  71..77   MASK BAND     7 sprites, opaque rows only, any colour — a bar
raster  77       IRQ: mask -> gameplay handoff, batch 0
raster  78..246  PLAYFIELD     matrix rows 2..23, first row clipped by the mask,
                               last row clipped by the border at 247
raster  250      frame transaction (unchanged) + mask sprite setup for next frame
```

- Top edge: the terrain's first row starts at L1 ∈ [71, 78] depending on
  `ys`; the mask covers 71…77, so the visible top edge is fixed at 78 and the
  first row is progressively revealed. Pixel-smooth.
- Bottom edge: row 23 at 232+ys…239+ys is always fully visible; row 24 at
  240+ys is clipped at 247 by the border. Pixel-smooth, zero cost, and sprites
  exit through it cleanly.
- HUD text is characters: 40 columns, any font, stamped into rows 0–1 of
  **both** pages (80 bytes each), updated on the displayed page anywhere
  outside rasters 55…70 — a 300-line window. No sprite cost.
- The mask sprites are static: X = 24+48i, Y = 56 (display 57…77, rows 14–20
  opaque), pointer to one 64-byte block, one colour, `$d01d` set. They are
  written once per frame at 250 into HW1–HW7 in place of today's batch 0.
  Their colour is free: a black band is invisible; a dark grey band is a frame
  line between HUD and playfield.
- Gameplay sprites: HW2–HW7 from the 77 handoff, first admissible Y ≈ 82.
  Lose four lines of sprite range at the top, none at the bottom. The player
  base HW0 is never touched by the mask; the overlay HW1 is programmed at the
  77 handoff instead of at 250.
- Costs: three short IRQs at 65/71/77 (≈50, ≈50, ≈350 cycles) and seven sprites'
  DMA over 21 lines (≈400 cycles of theft). ≈4% of the frame. The border phase
  (≈410 cycles, a raster poll) and its RSEL games disappear.
- Playfield height 169 lines (21.1 rows) against 192 today. The HUD takes 16,
  the mask 7.

### 4.5 The YSCROLL split — the part that is genuinely subtle

A split under fine scroll has an eight-phase hazard that must be designed, not
discovered. Let B be the HUD's last badline (63). The terrain's first badline
must be L1 = B + 8 + d where d = (ys − B) & 7, and **no badline may occur in
(B, L1)**, otherwise the VIC repeats a row (a badline on a row's eighth line
reloads VC from a VCBASE that has not advanced yet) or starts the terrain
early. Two rules keep every write safe on real hardware:

- a `$d011` write must land on a line whose low three bits equal **neither**
  the old **nor** the new YSCROLL. Equal-to-old means a badline is in flight;
  equal-to-new after cycle 14 is a *late badline*, the VSP family, and on some
  boards that corrupts DRAM. Neither is acceptable "occasionally".
- from a write on line W the next badline for the new value is at most W+7
  away, so for d = 7 a single write cannot reach L1 = B+15 without landing on
  B+8 before cycle 14 — a cycle-exact write, which sprite DMA on that line
  (seven mask sprites steal cycles 0–10) makes impossible.

The two-write scheme avoids all of it, with no cycle exactness and no jitter
sensitivity:

```
line B+2 (65):  YSCROLL = (d == 0) ? old : old+1     "park"
line B+8 (71):  YSCROLL = new
```

Check: line 65 has residue 2, park is 0 or 1, old is 7 → safe. Lines 66…71
have residues 3,4,5,6,7,0 — the park value (1) never matches, so no badline;
the old value (7) is gone before 71. Line 71 has residue 7 ≠ park, and ≠ new
for d ≠ 0; for d = 0 new = old = 7 and the write is a same-value rewrite during
a badline already in progress, which is harmless. After 71, the first line with
residue `new` is 72+d−1 … = B+8+d = L1. Every phase, every write on a safe
line, no poll loops. **The IRQs at 65 and 71 must never be late** — they sit
above the first gameplay batch, so nothing chases them, but §8 asks for the
executor to treat them as unchaseable explicitly.

### 4.6 The alternative the mandate asks for — costed honestly

If the HUD **must** be sprites in the top border, the border stays open and
both aperture edges need a mask:

```
raster ~237   IRQ: bottom mask setup (HW1-7, Y=246, rows 0-7 opaque)
raster  243   border-open phase (unchanged)          gameplay Y max ≈ 215
raster  250   frame transaction only
raster  ~16   HUD phase: HW2-7 (Y ≤ 15 to end by 36)
raster  ~37   IRQ: HUD -> top mask handoff (HW1-7, Y=40, rows 7-13 opaque)
raster  ~62   IRQ: top mask -> gameplay handoff, batch 0   gameplay Y min ≈ 66
```

Four ownership phases, three full-pool handoffs (~1,000 cycles), ~1,200 cycles
of extra sprite DMA, every gameplay sprite culled ≥11 px inside the top edge
and ≥10 px inside the bottom edge (an enemy cannot slide out through either
edge — it disappears early or overlaps the HUD), and the player overlay HW1
time-shared with the bottom mask in a five-line window. It is implementable and
deterministic. It is not boring, and it spends the resource a shooter most
needs — sprite freedom at the edges — on a HUD that could be characters.

My recommendation is §4.4. If the sprite HUD is kept, at least keep it *inside*
the display: sprites at Y≈54 over the two blank HUD rows need no border trick,
no bottom mask, and can share slots with the top mask (Y-expanded, content rows
above, opaque rows below, multicolour for a second colour) — but the character
HUD remains cheaper and sharper.

## 5. Interaction with the current border opening

Under §4.4 `exBorder` is deleted. Under §4.6 it stays, and the following apply
either way while it exists:

- **The RMW on `$d011` is wrong in principle.** Reading `$d011` returns the
  current raster's bit 8 in bit 7; writing bit 7 sets the raster-compare high
  bit. At 243–249 both are 0 so it works. If this phase ever entered at a
  raster ≥ 256 — a long enough late chain — the RMW would arm compare line
  250+256 and the frame IRQ would never fire again. The fix is to write the
  full byte from the frame record (`frameD011,x` with bit 3 set/cleared),
  never to read the register. Same for the `and #$f7`.
- The poll `cmp #249 / bcc` compares the **low byte** only. Entered at
  ≥ 256 it spins until raster 249 of the *next* frame inside the IRQ with I
  set. Unreachable today (last MAXCAP batch 176, last ring batch 212), but
  unguarded.
- The poll is not expensive (≈410 cycles) and is in the vertical blank; the
  cost is not the problem, the loss of the clip is.
- RSEL=1 for lines 243–249 is display-inert (no badlines above 247, and
  RSEL only moves the comparison lines), so no badline consequence. Correct as
  far as it goes.
- It does not conflict with the frame transaction. It does conflict with any
  bottom-edge clipping, permanently.

## 6. HUD → gameplay ownership handoff

The proposed ordering (250 publication only; HUD in the top border; handoff at
~40–50; gameplay from 55) is **sound in raster order** and the register table
in `border-handoff-scroll-mask.md` §7 is the right contract. Adjustments:

- **Where batch 0 is programmed** must be after the last DMA line of whatever
  previously owned those slots, not before its last *displayed* line — the
  pointer is fetched each line, so rewriting it early corrupts the previous
  owner's remaining rows. Under §4.4 the mask's last DMA line is 76, so 77.
- **Lead**: batch 0 needs the same REUSE_LEAD discipline as any batch — its
  six writes (≈300 cycles ≈ 5 lines, plus a badline in that span) must finish
  before the first sprite's Y compare (cycle 55 of line Y). Handoff at 77 →
  first Y ≥ 82. Under §4.6 with a handoff at 62, first Y ≥ 67.
- **Restore unconditionally at every handoff**: `$d010`, `$d015`, `$d017`,
  `$d01b`, `$d01c`, `$d01d`, and per used slot X/Y/pointer/colour. The mask
  needs `$d01d` set for its slots; gameplay needs it clear. Inherit nothing.
- **Cleaner ownership schedule**: make each phase a schedule entry of the same
  shape as a batch — line, slot set, register image — so the executor stays
  decision-free and a test can assert "phase P wrote register R at line L".
  The frame transaction then owns only `$d011/$d018/pointer-dest/$d015`, as
  the previous report proposed.
- **Badline conflicts**: the 77 handoff straddles a badline (L1 ∈ 71…78 and
  L1+8); budget 43 stolen cycles. The 65/71 writes are ≈20 cycles each and
  irrelevant. Under §4.6 the top-border phases are badline-free but the 62
  handoff is not.
- The historical "Y≈18 stable, 20/22 not" is consistent with a HUD sprite's
  DMA colliding with a following phase's writes, not with a VIC limit;
  PAL's first visible line is ≈16, so Y ≥ 15 is a display constraint, not a
  stability one.

## 7. Recommended order of the next steps

1. **Run §3 A** on the clean build. If the band glitch is gone, close it as
   "HUD rows". Ten minutes.
2. If not, **§3 C and E** (solid sprites; monitor screenshot diff). Thirty
   minutes. Do not touch the executor until one of these speaks.
3. **Decide the HUD medium** with §4.6's costs in front of the decision. This
   is the architectural decision; everything below depends on it.
4. **Revert `exBorder`** (under §4.4) or fix its `$d011` writes (under §4.6).
   Either way the guard rows go: row 0 and row 24 become terrain again.
5. Implement the **YSCROLL split as a scheduled event** with the two-write
   scheme, plus the mask sprites in the frame transaction, plus the handoff.
   Verify with `frameEntryLine`-style instrumentation: record the raster of
   every `$d011` write, and assert no write ever lands on a line whose low bits
   equal old or new YSCROLL. That check is cheap and is the whole safety
   argument.
6. Re-measure the edges with a **scroll-compensated** diff (line y vs. line
   y−1 of the next frame). A fixed-raster diff will always "find a pop".
7. Only then: player layer.

## 8. Fix before adding game features

- **`regenPage` chosen by the main thread before adoption** (§1.2). Have
  `regenTick` derive the back page from `curPage` (the IRQ's adopted page), or
  refuse to run while `framePending` is set. Add the `regenPage == curPage`
  counter either way.
- **`$d011` RMW in `exBorder`** (§5) — or delete the phase.
- **`exLate` must not chase display-structural events.** Today only batches
  are chased and `curBatch == 0` guards the frame. When split/handoff events
  are added, a late one must be *dropped*, not chased into a wrong raster.
- **Write `$3fff = 0`** at init. VICE gives 0; hardware gives whatever was
  there, and with the border open (or any idle lines) it is displayed.
- **`publishSkip` behaviour**: a skipped record silently drops that frame's
  page flip and fine step; the next record then carries a 2-px move. If skips
  ever return, prefer "overwrite the pending record" to "drop the new one" —
  the pending one is stale by definition.

## 9. Scary in the diagnostics, not a production problem

- **The 12–15% skip rate.** Measured with the six-row diagnostic HUD stamping
  the back page and the displayed page every frame. With it off: RING-SLOW
  1 skip in 9,924 frames, MAXCAP 0 in 9,494. The main-thread ceiling P5 warned
  about was largely the diagnostics' own cost. Re-measure before any scheduler
  work; do not optimise `ROWS_PER_TICK` or the builder on the old number.
- **`statLate` saturated and `maxLateRun` 6–13.** Those are batches armed
  closer together than a handler takes, chased by design. MAXCAP at 6-line
  spacing and the ring at 1-line spacing are laboratory maxima; a 10–12 sprite
  game will rarely chain. Keep the instrument; stop reading it as a fault.
- **`schedBuildDefer` climbing.** It counts a race that the guard resolves
  correctly. It should be non-zero on any moving fixture.
- **Mid-screen invocations over 756 cycles.** Chains, not overruns, as the P5
  report already established.
- **The border phase's 410 cycles.** Cheap. Its problem is what it removes,
  not what it costs.

## 10. Where the evidence runs out

I have not seen the glitch, the screenshot cannot contain it, and the static
picture of the executor is clean. I will not name a root cause from that.
The three things that would change this review: run A still showing the band
(rules out the HUD era), run C still showing it (rules out perception), and a
monitor-screenshot diff showing a real frame-to-frame character difference in
rows 0–6 on a frame with `publishSkip` unchanged — at which point candidate 4's
mechanism is the template for what to look for, and the answer will be a
memory write, not a register write.

## Hygiene

`pgrep -fl x64sc` before: none. One launch, `-console`, pid 37733, reaped in
`finally`. No broad `pkill`, no `open -a`, no window. Probe script in the
session scratchpad, deleted. `build/` unchanged (68K); repository 2.5M.
