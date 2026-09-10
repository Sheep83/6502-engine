# Manual visual acceptance — P0

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

Press **SPACE** to step through the five fixtures. Dwell on each for at least
30 seconds; the failure this whole project exists to catch is intermittent.

The status line reads:

```
FIX nn   ACC nn   REU nn   MRG nn   UNS nn
```

fixture, accepted, reuse events, rejected inside our safety margin, rejected as
physically unsafe.

The **bottom row** carries the same thing in a form you cannot miss during a
long dwell, in reverse video, below the lowest sprite any fixture places:

```
FIXTURE n  SPACE = NEXT   KEY #
```

The block after `KEY` fills **only while the scan actually sees SPACE down**.
If you press SPACE and that block never lights, the machine is not receiving
the key — check the launch options above. The renderer is not the suspect.

## What you should see

| fixture | expected picture | ACC | REU | MRG | UNS |
|---|---|---|---|---|---|
| 0 | six numbered sprites `0`–`5`, evenly spaced down the screen | 06 | 00 | 00 | 00 |
| 1 | seven sprites `0`–`6`; sprite `6` is the first reuse | 07 | 01 | 00 | 00 |
| 2 | fourteen sprites `0`–`D` cascading down, each a different colour | 0E | 08 | 00 | 00 |
| 3 | six sprites `0`–`5` in one tight cluster; nothing else | 06 | 00 | 00 | 02 |
| 4 | six clustered sprites plus a single `9` below them | 07 | 01 | 02 | 01 |

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
