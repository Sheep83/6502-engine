# Manual visual acceptance — P0, P1 and P2

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

Press **SPACE** to step through the sixteen fixtures — five from P0/P1 and
eleven added by P2. Dwell on each for at least 30 seconds; the failure this
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
