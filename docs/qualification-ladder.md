# Qualification ladder

Each checkpoint is proven by deterministic fixtures **and** by a human watching a
non-warp run before the next is started. Each remains independently runnable —
P1 does not replace P0. Any smallest failing fixture is kept permanently.

| | checkpoint | status |
|---|---|---|
| **P0** | static screen + static pre-sorted sprites | **implemented** |
| **P1** | scrolling screen + static pre-sorted sprites | **implemented** |
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

## What P1 decided

P1 introduced the second screen page, and with it the one genuine tension in
this architecture: **two sprite-pointer tables** (`$07f8` for page A at `$0400`,
`$2bf8` for page B at `$2800`).

"Write both tables every time" was **not** adopted. The shape implemented is:

```
frame chooses the active screen
      -> renderer establishes ONE pointer-table destination for that frame
      -> every sprite pointer write that frame targets that page
```

**Mechanism: a single patched operand byte.** `$07f8` and `$2bf8` share the low
byte `$f8`, so the executor's one pointer store — `sta PTR_A,x`, labelled
`exPtrStore` — needs only its HIGH byte rewritten. The frame IRQ writes that one
byte, once, at the same instant it writes `$d018`. A raster batch therefore
cannot choose a destination even in principle: there is exactly one store
instruction in the whole program, and its target is already fixed before the
first batch of the frame runs.

`tests/test_p1.py` asserts all of this: one `sta $d018` in the source, one
pointer store, one writer of `exPtrStore+2`, and zero page/pointer mismatches
over a 23,000-frame run.

## What P2 must decide

Nothing structural. P2 sweeps sprite geometry against the scroller P1 built; see
`docs/p2-static-y-matrix.md`. The one thing P1 leaves for it is that the P1
fixtures never produce a **merged mid-screen batch** — every mid-screen batch is
one entry. `REUSE_LEAD` is sized for a six-entry merge that no current fixture
generates, so that budget is still argued rather than measured. P2's clustered
geometry is what will finally produce it.
