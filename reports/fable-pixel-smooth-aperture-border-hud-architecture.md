# Pixel-smooth aperture + top-border sprite HUD — architecture review

Independent design review. Source inspected (`src/renderer.asm`, `src/scroll.asm`,
`src/main.asm`, fixtures), the four reports read, three facts re-verified
against the tree (§9). Nothing modified, nothing run beyond `grep`.

**Recommendation in one paragraph.** Candidate A is impossible on the VIC-II: a
top-border HUD and native edge clipping use the *same* flip-flop, and there is
no event between raster 252 and 50 that can set it, so any open border means
no hardware clip at *either* edge, for characters *and* sprites. The
production path is Candidate B in a form the brief did not list: keep the
border open, and clip the two aperture edges with a **blank character set**
selected by two `$d018` writes per frame — one at raster 55 (blank→real) and
one at raster 248 (real→blank). Zero sprites, ~350 cycles, deterministic to the
cycle, hardware-standard, and the playfield keeps its full 24-row height. The
HUD then lives at Y≈18 in HW2–HW7, programmed at raster 4 and handed to
gameplay at raster 40, where batch 0 is programmed. The frame transaction stays
at 250 and becomes adoption-only. The one unavoidable cost of the border-HUD
requirement — which no architecture can remove — is that gameplay sprites
**cannot slide through either edge**; they appear/vanish at Y 55 and Y 226.

---

## 1. VIC-II constraints that matter

All from the flip-flop rules (Bauer §3.9), which the current border-opening
code already relies on and which VICE `x64sc` models exactly.

**Vertical border flip-flop.** It is **set** only when the raster reaches the
*bottom* comparison line in cycle 63 — **247** (RSEL=0) or **251** (RSEL=1).
It is **reset** only when the raster reaches the *top* comparison line in cycle
63 with DEN=1 — **55** (RSEL=0) or **51** (RSEL=1). No other set or reset
exists. DEN=0 can *prevent* the reset; nothing can force a set anywhere else.

Consequences, stated precisely:

- The bottom border, the vertical blank and the top border (rasters 248…54)
  are **one region** of flip-flop state. Whatever state line 251 leaves is the
  state at line 48 next frame. **You cannot open the top border and keep the
  bottom closed, or vice versa.**
- Native top clipping at 55 *is* the flip-flop being set through 252…54, i.e. a
  closed top border. **HUD sprites visible in the top border ⟺ flip-flop not
  set ⟺ no native clip at 55 and none at 247.** Mutual exclusion, not a timing
  problem.
- With the flip-flop open, lines outside the display window show the VIC's
  **idle graphics**: the byte at `$3FFF` in bank 0, 0-bits in `$d021`. The
  "border" is therefore `$d021`-coloured and `$d020` is irrelevant everywhere.
  `$3FFF` must be **0** and must be *made* 0 at init — hardware RAM is not
  zero at power-on.

**Badlines.** `raster ∈ [48,247]` and `raster & 7 == YSCROLL` and DEN. The CPU
is stalled from cycle 12 to 54 of a badline (three write-only cycles allowed
after BA falls). Lines ≥ 248 and ≤ 47 are **never** badlines.

**Character fetch timing.** g-accesses (glyph bytes) occur in cycles 16–55 of
every display line and compute the address from the *current* `$d018` CB bits
per access. A CB change in cycles 56…15 therefore takes effect cleanly at the
next line; a change in 16…55 tears mid-line at a character boundary. This is
the standard split-screen-charset mechanism every game uses.

**Sprite Y compare is 8-bit.** DMA turns on when `Y == RASTER & $FF` with the
enable bit set. PAL has 312 lines, so a sprite with **Y ≤ 55 also matches at
Y+256** (lines 256…311). Normally the closed border hides that; with the
border open the ghost is *visible*. This bites a Y=18 HUD (ghost at 274–294)
and is the reason the HUD must be enabled *after* line 274.

**Sprite pointer fetch** is per line from the current VM page's `$xxF8` bytes.
Pointer writes for a slot are safe any time that slot's DMA is off.

**`$d011` writes.** Bit 7 of a *read* is RST8 (raster bit 8), bit 7 of a
*write* is the raster-compare high bit; a read-modify-write is therefore only
safe while the raster is < 256. Writing the same YSCROLL back mid-line creates
no new badline condition; writing a *different* YSCROLL inside 48…247 can create
a late badline, which is the VSP family and is excluded.

## 2. Candidate A — native 24-row clipping with an open top border

**Impossible, by §1.** The top edge of the display window at 55 is not a clip
applied to an open border; it is the flip-flop *being closed* from the previous
frame's 247 until 55. To have it closed at 48…54 it must have been set at 247 or
251, which closes the entire top border. There is no "toggle RSEL back"
sequence that restores it, because the only reset lines are 51/55 and the only
set lines are 247/251; no write to any register creates a set event in 252…50.

The same argument kills the mirror image (bottom-border HUD, top clip native)
and any "open top, keep bottom" scheme. **Rejected — VIC-II fact, not a design
preference.**

## 3. Candidate B — open border, synthesised edges

The aperture must hide the scroll slack: matrix row 0's lines above the top
edge (48+YSCROLL … 54, up to 7 lines) and matrix row 24's lines below the bottom
edge (248 … 247+YSCROLL, up to 7 lines). Everything above 48+YSCROLL and below
247+YSCROLL is already idle (blank) by §1. Four mechanisms:

| mechanism | sprites | timing precision | clips sprites? | rows lost | verdict |
|---|---|---|---|---|---|
| **B1 blank charset, two `$d018` writes** | 0 | store cycle ≤15 on lines 55 and 248; 3-cycle margin by construction | no | 0 | **recommended** |
| B2 seven X-expanded mask sprites per edge | 7 top + 7 bottom | none | yes (by slot ownership) | 0 | fallback |
| B3 HUD-as-mask (HUD rows 0–13, opaque rows 14–20 at 48–54) + B1 or B2 at bottom | 7 top | none at top | top yes | 0 | fallback variant, forces X-expanded (2×) HUD glyphs |
| B4 DEN / RSEL splits | 0 | — | — | — | **cannot work**: DEN skips a row's badline → the row is dropped whole, not clipped; RSEL only moves comparison lines |
| B5 colour occlusion ($d021 split) | 0 | must land in horizontal blank (cycle-exact) | no | 0 | reject: needs a stable raster and still cannot clip sprites |

### B1 in detail

A 2 KB block of zeros at **`$3800–$3FFF`** (free in VIC bank 0; §9) is a
character set in which every glyph, reverse or not, multicolour or not, renders
as `$d021`. It also contains `$3FFF`, so the idle byte is 0 by construction.
Real charset stays at `$1000` (ROM). `$d018` CB bits: real `%010` (`$04`),
blank `%111` (`$0E`); VM bits unchanged per page.

**Top edge, T = 55.** Write `VM|$04` in the window `[54:56 … 55:15]`. Line 55 is
a badline when YSCROLL=7 — but for YSCROLL=7 row 0 starts *at* 55 and lines
48–54 are idle, so no blanking is needed and the write may land any time
before 55:12. For YSCROLL ≠ 7 line 55 is not a badline. So:

```
exTop (IRQ at 54):
    ys == 7  ->  sta $d018 immediately            ; no timing requirement
    else     ->  cpx $d012 / bne (7-cycle loop, X = 55), then sta $d018
```

The 7-cycle poll guarantees a detection read in cycles 0…6 of line 55, so the
store lands in cycles 6…12 — before 16, and line 55 cannot stall. Line 54
*may* be a badline (YSCROLL=6): the poll is simply stalled through it and
resumes at 54:55, still detecting 55 in 0…6. Margin: 3 cycles, deterministic.

**Bottom edge, E = 248.** Write `VM|$0E` in `[247:56 … 248:15]`. Line 248 is
never a badline. Line 247 is (YSCROLL=7) — the poll rides through it. Store
lands in 248:6…12. The only other stall source is sprite DMA on 247/248, which
is excluded by a builder rule **MAX_SPRITE_Y = 226** (a sprite at Y=226 ends
DMA at 246). Margin: 3 cycles, deterministic.

Why E=248 and not 247: any E ≤ 248 gives a pixel-smooth bottom (new row 24
content enters one line at a time; E ≥ 249 pops in 2+ lines at each coarse
step because the newly-revealed row 24 jumps in at once). 248 is the largest
smooth value and the only one outside the badline zone. Playfield = 55…247 =
**193 lines**, one more than RSEL=0 mode.

The switch back to real at the top can also be done with no precision at all
by B3's mask — but B1 already has the precision for free through the ys==7
observation, so B3's seven sprites buy nothing.

**What B1 cannot do:** clip sprites. With the border open nothing clips sprites
except a mask sprite in front, and there are not enough sprites for that at
both edges while six are multiplexing. This is the border-HUD requirement's
irreducible cost — see §10.

### B2 in detail (fallback)

Top mask: seven sprites, X-expanded (48 px × 7 = 336 ≥ 320), placed so rows
covering 48–54 are opaque; must vacate the slots by 55 → mask Y ≤ 34 → the HUD
must end by 33 (Y ≤ 13, partly off-screen) unless the HUD *is* the mask (B3).
Bottom mask: seven sprites at Y=247, requiring HW1–HW7 free by ~245 → gameplay
Y ≤ 224 and the player overlay HW1 excluded from the bottom 22 lines. Four
ownership phases, three handoffs (~1,000 cycles) plus ~600 cycles of mask DMA:
≈ 8 % of the frame, and a 2×-wide HUD if B3 is used. Deterministic and
hardware-safe; simply worse than B1 in every column. Keep as the fallback if
B1's two splits fail measurement (§10 says how to measure).

## 4. Candidate C — fixed HUD rows inside the display, border closed

This is what my previous review recommended, and it is the *only* design that
restores native clipping for sprites as well as characters (enemies slide in
and out through both edges for free). But it is **not a border HUD**: the HUD
would sit inside the display window at rasters 55–70, drawn as characters, and
the border stays closed. Calling that "a border HUD because the display looks
like it" would be redefining the requirement, so **rejected against the stated
requirement.** Recorded only so the trade is explicit: the border HUD is being
bought with sprite edge clipping at both edges. If that price is ever judged
too high, C is the design to return to.

## 5. Ranked recommendation

1. **B1 — blank-charset edge splits, HUD in HW2–HW7 at Y≈18, batch 0 at a
   raster-40 handoff, raster-250 adoption-only.**
2. Fallback — B2/B3 sprite masks, only if B1's splits fail per-phase
   measurement in VICE (they should not: the margins are arithmetic, not luck).
3. Reject — A (impossible), C (violates requirement), B4/B5 (do not clip), and
   the current blank guard rows (they *are* the 6.25 Hz artefact).

## 6. Recommended raster phase diagram

```
raster  246  exBottom    $d011 = rec|RSEL=1 (full byte, from CURRENT record)
                         poll to 248 (7-cycle loop)
                         $d018 = VM_cur | $0E          <- bottom edge, blank charset
                         $d011 = rec (RSEL=0)          <- second close (251) also missed
                         arm 250
raster  250  exFrame     adopt frame record + schedule record (unchanged)
                         $d011 = new (RSEL=0, DEN=1, ys)
                         $d018 = VM_new | $0E           <- page flip, still blank
                         exPtrStore+2 = new pointer-table page
                         $d015 = 0                      <- nothing enabled across vblank
                         arm 4
raster    4  exHud       HW2..HW7 <- HUD image: X, Y=18, ptr, colour, $d010,
                         $d017/$d01b/$d01c/$d01d as the HUD needs, $d015 = hudEnable
                         arm 40                         (Y written after 274: no ghost)
raster   40  exHandoff   $d017=0 $d01b=0 $d01c=0 $d01d=0 ($d025/$d026 if HUD used MC)
                         batch 0 -> HW2..HW7 (X, Y, ptr, colour), $d010 = batchD010[0]
                         $d015 = schedEnable
                         arm 54
raster   54  exTop       ys==7 ? write now : poll 55 ; $d018 = VM_new | $04   <- top edge
                         arm first mid-screen batch line (>= 68) or 246
raster  68+  exBatch     mux batches exactly as today; last <= 214 (MAX_Y 226 - 12)
                         exArmFrame -> arm 246
```

Visible structure:

```
 16.. 38   HUD sprites over $d021 (open border)
 39.. 54   $d021, no terrain, no sprites (slots in handoff; Y<55 forbidden)
 55..247   scrolling terrain, 193 lines, both edges pixel-smooth
248..311   $d021 (blank charset then idle)
```

Border/RSEL/DEN strategy: DEN=1 always; RSEL=0 always except 246:~10 → 248:~20
where it is 1 so the 247 close misses, then 0 so the 251 close misses. The
flip-flop is therefore never set; this is the existing mechanism, retained.

Bottom-edge behaviour: row 24 is revealed one line per frame from 248 upward
as YSCROLL counts down; at the coarse step it becomes row 23 in the same place.
No pop. Top edge symmetric at 55. **Guard rows are deleted**; rows 0 and 24
carry terrain again.

## 7. HUD → gameplay ownership contract

Every phase writes every register its predecessor *might* have changed,
unconditionally; nothing is inherited.

| register | exFrame 250 | exHud 4 | exHandoff 40 | gameplay batches |
|---|---|---|---|---|
| `$d000–$d00f` X/Y | — | HUD slots, all used | batch-0 slots | per entry |
| `$d010` | — | complete HUD value | complete batch-0 value | complete per batch |
| `$d015` | **0** | hudEnable | schedEnable | — (once per frame) |
| `$d017` `$d01b` `$d01d` | — | HUD's values | **0** | — |
| `$d01c` | — | HUD's value | **0** (already today) | — |
| `$d025/$d026` | — | if HUD is MC | restore gameplay's (unused today) | — |
| `$d027–$d02e` | — | HUD slots | batch-0 slots | per entry |
| pointer table | dest = new page | HUD slots, new page | batch-0 slots | per entry |
| `$d011` `$d018` | full frame value | — | — | — |

- Slots enabled in `$d015` but not in batch 0 cannot exist (batch 0 is the
  first `min(6, accepted)` entries, so every enabled slot is in it) — the same
  invariant as today, now load-bearing across the handoff.
- **Pointers are always written through `exPtrStore`**, i.e. the page adopted
  at 250. The HUD phase runs after 250, so it targets the new page; correct.
- **Lead for batch 0:** written by ~46 (40 + ~350 cycles, no badline, no sprite
  DMA in 40–46). First legal Y = 47; the design uses **MIN_SPRITE_Y = 55** so
  no gameplay sprite ever has a ghost (Y ≤ 54 ghosts at 310–311+; 55 ghosts
  only at line 311, which does not exist visibly). Existing fixtures already
  start at 55.
- **HUD Y must be written after line 274** (its own ghost line) — hence the
  raster-4 phase, not 250 — and `$d015 = 0` from 250 to 4 so nothing at all is
  enabled during the vertical blank.
- Batch 0 **is** the handoff: the handoff IRQ is "restore shared registers,
  then execute batch 0". One phase, one owner change.
- HUD bitmap updates by the main thread must avoid rasters 16–38 (or
  double-buffer the pointer). Trivial with a 280-line window.

## 8. Batch-0 recommendation

Move it out of `exFrame` into `exHandoff` at raster 40. Reasons: the 250
transaction is then adoption-only, as the brief proposes; batch 0's writes land
after the HUD's last DMA line (38) and 15 lines before the terrain edge;
`frameEntryLine == 250` is untouched; and the executor stays decision-free —
`exHandoff` reads `batchLine[0]` is no longer 250 but a constant 40, so the
builder writes `HANDOFF_LINE` into batch 0's line field and nothing else about
the schedule shape changes. The proposed ordering in the brief is sound;
"~40–50" should be **40** with a Y=18 HUD (gap 39–54 is the handoff's
working room). Moving the HUD lower (Y up to ~26) shrinks the gap but pushes
the handoff to 48 and the ghost line into VICE's visible area (≤287); tune
later with the pixel harness, start at 18.

## 9. Expected timing / cycle cost

| phase | cycles | note |
|---|---|---|
| exBottom 246→248 | ~250 | ~130 of it is the poll, inside the border |
| exFrame 250 | ~500 | today's 850 minus batch 0 |
| exHud 4 | ~200 | six sprites, static image |
| exHandoff 40 | ~380 | four resets + batch 0 + `$d015` |
| exTop 54 | 60–110 | poll only for ys ≠ 7 |
| HUD sprite DMA | ~300 | 6 × 21 lines |
| **structural total** | **~1,700** | **8.6 %**; today 1,260 + batch-0 DMA-free |

Net change ≈ +2 %. Main-thread budget is unaffected; the 12–15 % skip figure
was already shown to be the diagnostic HUD's cost, not the engine's.

Facts re-verified in the tree for this section: `$2C00–$3FFF` has no segment
(highest bank-0 placement is p5 tables at `$2400`, screen B at `$2800`);
`installRenderer` clears RST8 (`and #$7f`); fixture Y range is 55…224 (P0 F1/F2
at 55, P5 ring to 224, P3 motion to 215, MAXCAP accepted ≤ 188). The P2
vertical sweep drives sprites to 238 and must be clamped to 226 — a test
change.

## 10. Risks and real-hardware concerns

1. **The two splits' 3-cycle margins.** Arithmetic, not luck, and identical on
   hardware — but they must be *measured*: `pinFine` 0…7 with a screenshot diff
   of lines 54/55 and 247/248 (the harness from the A/B task does this
   directly), plus natural scrolling. A torn line shows as a right-hand
   partial row of glyphs on one line; the test is unambiguous.
2. **MAX_SPRITE_Y = 226** must be enforced in `buildSchedule` (reject, count)
   and audited over every fixture, because a sprite active on 247/248 slips the
   bottom split by up to 12 cycles.
3. **Sprites pop at both edges.** Not a risk — a consequence of the requirement
   (§1, §4). Enemies appear at Y ≥ 55 and vanish when Y would exceed 226. The
   game design must own that; no raster trick recovers it while the border is
   open.
4. **`$3800–$3FFF` must be cleared at init**; power-on RAM is garbage and the
   blank charset and idle byte both live there.
5. **`$d020` is dead; `$d021` colours the whole frame** including the HUD band.
   A differently coloured HUD band would need cycle-exact `$d021` splits —
   don't.
6. **`$d011` writes must be full bytes from the CURRENT record**, never RMW —
   see §13.
7. **Structural phases must never be chased.** A late `exBottom` (chain past
   246) closes the border for a frame; `MAX_Y = 226` puts the last batch at
   ≤ 214 so it cannot happen, but add `edgeEntryLine` min/max counters like
   `frameEntryLine` so the invariant is *checked*, not assumed.
8. **HUD ghosting** if anyone later programs a HUD Y before line 274 or leaves
   `$d015` bits set across the blank. The contract in §7 prevents it; a test
   should assert `$d015 == 0` at raster 260.

## 11. Implementation slices for Claude

Each changes one mechanism and has a measurable gate.

**Slice 1 — aperture only.** Blank charset at `$3800` (cleared at init);
`exBottom` replaces `exBorder` (same RSEL trick, full-byte `$d011`, plus the
248 split); `exFrame` writes blank CB; new `exTop` at 54; guard rows deleted.
Batch 0 stays at 250 for now. Gate: A/B-task harness shows **zero residual at
every pair including flips** (page-letter column excepted), `pinFine` 0…7
frames identical with lines 48–54 and 248–254 blank; FIX16 manual: no 6.25 Hz
bar.

**Slice 2 — batch 0 to a handoff at 40.** `HANDOFF_LINE`, `exHandoff` with the
four unconditional resets, `$d015 = 0` at 250, `MIN_Y 55 / MAX_Y 226` in the
builder with a fixture audit (clamp the P2 sweep). Gate: `test_p2/p3/p4/p5
--fast` unchanged, `frameEntryLine == 250`, `$d015 == 0` sampled at 260,
handoff entry line always 40.

**Slice 3 — HUD phase.** `exHud` at 4 with a static six-sprite image (any
bitmaps), `hudEnable`. Gate: HUD band pixel-identical frame to frame; no ghost
at 274–294 (screenshot lines 258–278 all `$d021`); gameplay tests unchanged.

**Slice 4 — HUD content and update discipline.** Real digits, main-thread
updates outside 16–38 or pointer double-buffering. Gate: HUD updates never tear
(pixel diff of the band on update frames).

**Slice 5 — regression and manual.** `make test-fast`, then `test-full` once,
then the manual list in §12.

Slices 1 and 2 are independent and could be swapped; do 1 first because it is
what the user is waiting to see, and it does not touch sprite ownership.

## 12. Manual qualification plan

`make run`, normal speed, windowed.

1. Any scrolling fixture: the topmost terrain line **enters** and the
   bottommost **leaves** one pixel per frame; no whole-row pop at either edge.
2. FIX16: no 6.25 Hz bar behind the top sprite row for 30 s.
3. HUD sprites still and sharp in the top border; nothing visible at the
   bottom of the screen (no ghosts).
4. Watch rasters 39–54 (the gap) and the HUD→gameplay boundary for any flicker
   of the first sprite row on any fixture, especially `1F`–`21`.
5. Gameplay sprites correct on `16`, `1F`, `20`, `21` for a minute each.
6. Leave RING-SHIFT for two minutes: repeated page flips and the full ±14 sweep
   with both splits live.
7. Slow-motion sanity: `pinFine` each phase — lines 48–54 and 248–254 must be
   pure background in every one.

## 13. The current `exBorder`: keep, remove, rewrite

- **Keep the mechanism** — missing both closes by toggling RSEL between
  247:63 and 251:63 is correct and the only way to hold the flip-flop open.
- **Rewrite the writes:** `lda $d011 / ora #$08 / sta $d011` reads RST8 into
  bit 7; benign at 243–249 today, a latent raster-compare corruption if the
  phase is ever entered at ≥ 256. Write `frameD011,x | $08` and `frameD011,x`
  from the CURRENT record instead. Same for the `and #$f7`.
- **Move it:** from a separate phase at 243 into `exBottom` at 246, where the
  same poll that waits for 248 serves the RSEL sequence and the charset split.
  The 243 phase and `exBorderPending` go away; the dispatch in `irqHandler`
  gains no new branch because 246 replaces 243 one-for-one.
- **Remove:** `renderGuardRow` and the row-0/24 special case in `renderRow`,
  the `HUD_ROW_*` reservation chain (already switched off), and the comment
  block claiming the border "cannot be used to shrink the aperture" — true,
  and now irrelevant, because the aperture is no longer the border's job.
