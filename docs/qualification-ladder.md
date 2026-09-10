# Qualification ladder

Each checkpoint is proven by deterministic fixtures **and** by a human watching a
non-warp run before the next is started. Each remains independently runnable —
P1 does not replace P0. Any smallest failing fixture is kept permanently.

| | checkpoint | status |
|---|---|---|
| **P0** | static screen + static pre-sorted sprites | **implemented** |
| P1 | scrolling screen + static pre-sorted sprites | not started |
| P2 | deterministic static-Y stress matrix + scrolling | not started |
| P3 | scripted moving Y positions, externally predetermined | not started |
| P4 | persistent / Ocean-style Y sorter | not started |
| P5 | generic logical sprite input | not started |
| P6 | fixed player base + second player layer | not started |
| P7 | collision / fire integration | not started |
| P8 | top-border HUD + border-opening / handoff timing | not started |
| P9 | terrain / turret interaction | not started |
| P10 | real wave / gameplay integration | not started |

## The final integrated target

Not a gameplay demo. An intentionally **synthetic** proof, harder than ordinary
play, that can be started and simply watched for a long non-warp run:

> a PAL C64 continuously scrolls the double-buffered playfield, executes the
> top-border opening and six-sprite HUD timing, and displays the chosen maximum
> gameplay sprite geometry through deterministic multiplexing with no
> corruption, flicker, missed scroll publication or register-ownership ambiguity.

with deterministic sprite patterns, predetermined Y movement, continuous
scrolling, every fine-scroll phase, repeated coarse page flips, and no
dependence on player skill or random encounters.

## What P1 must decide

P1 introduces the second screen page, and with it the one genuine tension in
this architecture: **two sprite-pointer tables** (`$07f8` for page A at `$0400`,
`$2bf8` for page B at `$2800`).

Do **not** adopt "write both tables every time" as the production model. The
intended shape is:

```
frame chooses the active screen
      -> renderer establishes ONE pointer-table destination for that frame
      -> every sprite pointer write that frame targets that page
```

by patched store address, a prepared pointer base, or two tiny executor paths.
Whichever is chosen, the ownership must stay singular: one destination per
frame, decided by the renderer, never by blind duplication.
