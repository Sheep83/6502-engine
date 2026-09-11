# Manual visual acceptance — P0, P1, P2, P3 and P4

**This is the authoritative test.** Automated results do not override it.

## Procedure

```sh
make run
```

That launches `x64sc` at **normal speed with no monitor attached** — the only
configuration in which what you see is what the machine really does. (A harness
cannot observe a freely-running non-warp machine: any monitor command halts the
emulator.)

VICE is held in the **foreground**: the terminal or VS Code task that started
it stays busy until you quit the emulator, and stopping that task stops VICE.

**Launch it through `make run` or the VS Code task, never a bare `x64sc`.**
The options in `VICE_OPTS` are not cosmetic. `-default` ignores your saved
`vicerc`, `+saveres` stops the run writing settings back over it, and
`-joydev1 0 -joydev2 0 +keyset` detach both joystick devices. Without those,
a joystick **keyset** can bind the host SPACE key to an emulated joystick;
VICE then consumes the key and the C64 keyboard matrix never sees it, so
fixture selection is silently dead and nothing on screen explains why. That is
a real failure this project already had — see §17 of the P0 report.

Press **SPACE** to step through the thirty-one fixtures — five from P0/P1,
eleven added by P2, eight by P3 and seven by P4. **M jumps to the first P3
(moving) fixture (16) and S to the first P4 (sorting) fixture (24)**, so neither
set is more than two keys away. The bottom bar says so:
`FIXTURE nn  SPACE=NEXT  M=3  S=4  KEY`.

Fixture numbers are shown in **hex**, as `FIX nn` always has been: fixture 16
reads `10`, fixture 23 reads `17`. Dwell on each for at least 30 seconds; the failure this
whole project exists to catch is intermittent.

**Fixture 5 is the one to leave running.** It is the six-entry merged batch:
six sprites all reprogrammed onto one raster, the case the whole reuse margin
exists for. Five presses of SPACE from a cold start. Leave it for several
minutes.

The status line reads:

```
FIX nn   ACC nn   REU nn   MRG nn   UNS nn
```

fixture, accepted, reuse events, rejected inside our safety margin, rejected as
physically unsafe.

Row 21 states what P3 and P4 added:

```
MOV n  MFRM nnnn  OVF nn  SRT nn  FLT nn
```

| field | meaning | expected |
|---|---|---|
| `MOV` | this fixture has trajectories, so the schedule is rebuilt every frame | `1` on fixtures 16–21 and 23, `0` otherwise |
| `MFRM` | frames of motion; the index a trajectory is defined against | climbs continuously on a moving fixture |
| `OVF` | logical sprites that did not fit `MAX_SCHED` | `00` everywhere except `MAXCAP` (`06`) and `SORTCAP` (`02`) |
| `SRT` | sorted count — how many logical IDs the sorter handed the builder | equals `LOG` on row 22; P4 has no visibility filtering |
| `FLT` | sorter fault, saturating | **always** `00` |

If `MFRM` freezes while the playfield keeps scrolling, the main thread has
stopped preparing frames — that is a failure whatever else looks right.

Row 22 states the P2 geometry:

```
LOG nn  MXB nn  OFF nn  B6 nnnn  PH n  PG A
```

logical sprites offered, the widest **mid-screen** batch in the schedule, the
vertical sweep offset, the number of six-entry mid-screen batches the executor
has actually run (low 16 bits), the fine-scroll phase and the displayed page.

It sits at row 22, below the lowest sprite any P2 fixture places. Row 2 carries
the same phase and page, but on every P2 fixture the six leader sprites at
Y 60-65 cover it -- sprites are in front of characters -- which is why they are
repeated here.

`LOG` against `ACC` on row 1 is the whole acceptance story: where they differ,
sprites were rejected, and `MRG`/`UNS` say which kind. A fixture showing fewer
sprites than it lists is **correct**, not broken.

`B6` is the live proof that the merged batch is executing. On fixture 5 it must
climb continuously. If it freezes while the playfield keeps scrolling, the
six-entry batch has stopped running and the run has failed, whatever else looks
right.

Row 2 states the scroller:

```
SCR f  ROW wwww  PG A  CRS cccc
```

fine-scroll phase (7 down to 0), world row at the top of the screen, the screen
page being displayed, and the coarse-step count.

Row 23 carries the fixture in a form you cannot miss during a long dwell, in
reverse video:

```
FIXTURE n  SPACE = NEXT   KEY #
```

The block after `KEY` fills **only while the scan actually sees SPACE down**.
If you press SPACE and that block never lights, the machine is not receiving
the key — check the launch options above. The renderer is not the suspect.

## The scrolling playfield (P1)

Everything except the sprites scrolls upward, one pixel per frame. Every eight
frames the fine scroll wraps, the map steps one row, and the screen page flips.
The background is a diagnostic surface, not artwork:

| columns | what it is | what it catches |
|---|---|---|
| 0-1 | the row's own world row number, in hex | a stale, duplicated, skipped or out-of-order row |
| 3 | `A` or `B` — the page this row was written into | a torn page flip: every visible row must show the SAME letter |
| 5-39 | a solid bar every 4th world row | coarse steps, countable by eye |
| 6+(row mod 32) | a `*` marker | a clean diagonal; kinks mean rows are wrong |

**What you should see:** the hex column counting smoothly upward by one, the
page-letter column flipping wholesale between `A` and `B` every eight frames
(never a mixture), the bars marching up at a constant rate, and the `*` diagonal
staying straight.

### Additional P1 fail conditions

- two different page letters visible on screen at the same time;
- the hex row column skipping, repeating or jumping;
- a bar or marker that jitters instead of moving one pixel per frame;
- the picture snapping vertically at a coarse step;
- sprite corruption that only appears at a page flip.

### Known and expected

- The three HUD rows sit inside the scrolling matrix, so they **ride the fine
  scroll and wobble by up to 8 pixels**. Holding them still needs a mid-screen
  `$d011` write, which is a raster split — that arrives at P8. It is not a fault.
- Rows 0 and 24 are the scroll slack and are clipped by the border
  (`RSEL=0`, 24-row mode). Rows 1-23 are always fully visible.
- Sprites are in front of the characters, so a box can cover part of a HUD
  label. Row 23 is below the lowest sprite any fixture places.

## What you should see

| fixture | expected picture | ACC | REU | MRG | UNS |
|---|---|---|---|---|---|
| 0 | six numbered sprites `0`–`5`, evenly spaced down the screen | 06 | 00 | 00 | 00 |
| 1 | seven sprites `0`–`6`; sprite `6` is the first reuse | 07 | 01 | 00 | 00 |
| 2 | fourteen sprites `0`–`D` cascading down, each a different colour | 0E | 08 | 00 | 00 |
| 3 | six sprites `0`–`5` in one tight cluster; nothing else | 06 | 00 | 00 | 02 |
| 4 | six clustered sprites plus a single `9` below them | 07 | 01 | 02 | 01 |

### P2 fixtures

All P2 fixtures share the same leaders: six sprites `0`–`5` at Y 60–65, a tight
cluster near the top. What changes is what reuses their slots below.

| fixture | expected picture | ACC | REU | MRG | UNS | MXB |
|---|---|---|---|---|---|---|
| 5 `T6` | the six leaders, then **six** sprites `6`–`B` side by side on ONE row | 0C | 06 | 00 | 00 | 6 |
| 6 `T5` | the same with five on the row | 0B | 05 | 00 | 00 | 5 |
| 7 `T4` | four on the row | 0A | 04 | 00 | 00 | 4 |
| 8 `T3` | three on the row | 09 | 03 | 00 | 00 | 3 |
| 9 `T2` | two on the row | 08 | 02 | 00 | 00 | 2 |
| 10 `T1` | one sprite `6` below the cluster | 07 | 01 | 00 | 00 | 1 |
| 11 `SPLIT` | two sprites one pixel apart vertically — they must NOT share a batch | 08 | 02 | 00 | 00 | 1 |
| 12 `BNDPHYS` | leaders only. Both candidates rejected | 06 | 00 | 01 | 01 | 0 |
| 13 `BNDCONS` | leaders plus ONE sprite; the other is rejected by our margin | 07 | 01 | 01 | 00 | 1 |
| 14 `T6X3` | the leaders plus **three** rows of six — 24 sprites, the hardest frame | 18 | 12 | 00 | 00 | 6 |
| 15 `WORST` | the worst measured legal geometry, frozen as a fixture | 0C | 06 | 00 | 00 | 6 |

On fixtures 5, 14 and 15 the six sprites sharing a row must show **six distinct
numerals in six distinct colours, side by side, none overlapping**. Six boxes
where there should be six, all on one line, is exactly what a working six-entry
merged batch looks like. Five boxes, a flickering box, two boxes with the same
numeral, or a box in the wrong colour is a **failure**.

Fixture 14 is the endurance case: three such rows, 24 sprites, every slot
reprogrammed three times per frame. Leave it running.

Each sprite is a hollow box containing its **logical index in hex**, in its own
colour. That is the whole diagnostic: if sprite `B` ever shows a `5`, or two
boxes show the same numeral, or a colour is wrong, a pointer/colour assignment
is broken and it is obvious without any tooling.

## Fail conditions

P0 is **RED** if any of these appear, regardless of what the tests say:

- a numeral that does not match its position in the cascade, or a duplicate;
- a box that flickers, tears, or changes numeral/colour between frames;
- a sprite that appears where the fixture table says nothing should be
  (fixtures 3 and 4 must show *fewer* sprites than they list — that is correct);
- any visible corruption of the character display;
- anything that only goes wrong after a long dwell.

A **rejected** sprite is not a failure. Visible corruption is.

## P4 fixtures — crossing sprites

Press **S**, then SPACE to advance. All run over the normal scrolling playfield.

| # | hex | name | expected picture |
|---|---|---|---|
| 24 | `18` | `SORTSTATIC` | twelve still sprites: six in a row near the top, six side by side below. Their numerals are **not** in order — that is the point |
| 25 | `19` | `CROSS2` | two sprites passing each other vertically, over and over |
| 26 | `1A` | `CROSS6` | six sprites interleaving continuously above six still ones |
| 27 | `1B` | `PREDCHANGE` | two sprites swapping at the top; everything else still |
| 28 | `1C` | `SORTSHAPE` | one sprite sweeping down past five still ones; a sixth **blinks** |
| 29 | `1D` | `TIE6` | six still sprites over six more, side by side |
| 30 | `1E` | `SORTCAP` | four dense rows of six; `OVF` reads `02` |

### CROSS2 — the identity check

Two sprites, each with its own numeral and colour, pass through each other in Y.
**Watch the numerals, not the positions.** As they cross, each sprite changes
hardware slot — it is reprogrammed onto the slot the other one was using — and
the whole checkpoint exists to prove that changes nothing about what you see.

Fail on: an identity swap (a numeral or colour jumping to the other sprite), a
disappearance at the moment of crossing, a teleport, a duplicate, or a sprite
left behind at the old position.

### CROSS6 — leave running several minutes

This is the strongest human check before the ring. Six sprites interleave
continuously while six more below them are reused on the same six slots, so
physical-slot ownership churns every few frames.

Watch for: unexplained flicker; a wrong numeral or colour; identities swapping;
a stale sprite at a previous slot; a duplicate; an accepted sprite missing; a
horizontal jump from a bad `$D010`; corruption correlated with a page flip; the
scroll stuttering.

### SORTSHAPE — expected blinking, again

As in P3's `GAP33`, one sprite is **meant** to appear and disappear — but here
it is not because its own Y moved. Another sprite crosses ahead of it, which
changes which sprite is its same-slot predecessor, which changes its reuse gap,
which changes whether it is admitted. Judge it by `ACC` on row 1:

| `ACC` | sprites visible | verdict |
|---|---|---|
| matches | matches | correct |
| says accepted | one missing | **renderer failure** |
| says rejected | still visible | **stale sprite — failure** |

### SORTCAP — the ceiling fixture

Twenty-six sprites offered, twenty-four displayed, `OVF 02`. **This fixture is
deliberately past the main thread's budget** and is expected to stutter the
scroll occasionally — it is a measurement, not an acceptance case. What must
still be true is that the sprites themselves are correct: twenty-four of them,
right numerals, right colours, no duplicates, no stale sprites.

### Additional P4 fail conditions

- `FLT` on row 21 ever non-zero;
- `SRT` not equal to `LOG` on row 22;
- two sprites exchanging numeral or colour as they cross;
- a sprite vanishing exactly when it changes slot.

## P3 fixtures — moving sprites

Press **M**, then SPACE to advance. All of these run over the normal scrolling
playfield.

| # | hex | name | expected picture |
|---|---|---|---|
| 16 | `10` | `MOVE6` | six sprites, no reuse. One slides left/right, one up/down, one diagonally, one is still |
| 17 | `11` | `MSBFLIP6` | twelve still sprites in two rows. Each slot's upper sprite is on the opposite side of screen centre from its lower one |
| 18 | `12` | `X255` | as above, but two sprites slide back and forth across the middle of the screen |
| 19 | `13` | `YMOVE` | two groups of six drifting up and down together, never changing order |
| 20 | `14` | `GAP33` | six still sprites, and a seventh that **blinks** — see below |
| 21 | `15` | `SHAPE` | six still, one blinking, and a row of six that changes as the blinker comes and goes |
| 22 | `16` | `MAXCAP` | a dense column of 24 sprites; `OVF` reads `06` |
| 23 | `17` | `MOTION12` | the integrated one: twelve sprites all moving, six slots reused |

### MSBFLIP6 — leave running several minutes

Every one of the six physical slots is reused by a sprite on the **opposite
side of X=255** from the sprite above it. A stale `$D010` bit is therefore
impossible to miss: it puts a sprite 256 pixels from where it belongs.

Watch for:

- any sprite suddenly jumping about 256 pixels sideways;
- a sprite on the wrong side of the screen;
- a sprite disappearing at the moment its slot is reused;
- a wrong numeral or colour;
- the previous logical owner of a slot still visible.

### X255 — watch the crossings

Two sprites slide repeatedly across the 255/256 boundary, in both directions.
The movement must be **visually continuous**: a smooth slide through the middle
of the screen. A jump of ~256 pixels at the crossing is a stale-MSB failure.

### GAP33 — expected blinking, and how to tell it apart

The seventh sprite is **meant** to appear and disappear. Its reuse gap walks
`31 32 33 34 33 32 31 …`, one raster per frame, and admission is a pure function
of the current frame's geometry with no hysteresis — so it is admitted at gap 33
and 34 and rejected at 31 and 32.

Read `ACC` on row 1 while you watch:

- `ACC 07` and seven sprites visible — correct;
- `ACC 06` and six sprites visible — correct;
- `ACC 07` and only six visible — **renderer failure**;
- `ACC 06` and seven visible — **stale sprite, failure**.

Any mismatch between the count and what is on screen is a failure. The blinking
itself is not.

### MOTION12 — the endurance case

Leave it running for several minutes, across many page flips and coarse steps.
Twelve sprites move in X and Y every frame, six physical slots are reused every
frame, and some sprites cross X=255.

Fail conditions: unexplained flicker, a duplicated sprite, a stale sprite, a
wrong numeral or colour, tearing, a vertical snap, mixed A/B page letters, or
any corruption that correlates with a page flip.

### Additional P3 fail conditions

- `MFRM` on row 21 not advancing while the playfield scrolls;
- `OVF` non-zero on any fixture except `MAXCAP`;
- a sprite whose horizontal movement jumps rather than slides;
- the scroll stuttering by one frame (a publication skip; it must never happen).

### Additional P2 fail conditions

- on fixture 5, 14 or 15, fewer than six boxes on a shared row, at any moment;
- a box on a shared row that flickers, drops out, or swaps numeral or colour;
- `B6` on row 22 not advancing while the playfield scrolls;
- `MXB` reading anything other than the value in the table above;
- any of the above appearing only at a coarse step or page flip.

Automated measurement says the six-entry batch finishes 110 cycles inside its
deadline in the worst fine-scroll phase. That is a small margin — under two
raster lines — so this is precisely the fixture where a human watching a
non-warp run matters most.
