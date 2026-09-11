# Qualification ladder

Each checkpoint is proven by deterministic fixtures **and** by a human watching a
non-warp run before the next is started. Each remains independently runnable —
P1 does not replace P0. Any smallest failing fixture is kept permanently.

| | checkpoint | status |
|---|---|---|
| **P0** | static screen + static pre-sorted sprites | **implemented** |
| **P1** | scrolling screen + static pre-sorted sprites | **implemented** |
| **P2** | deterministic static-Y stress matrix + scrolling | **implemented** |
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

## What P2 decided

Nothing structural, as planned. P2 swept sprite geometry against the scroller P1
built; see `docs/p2-static-y-matrix.md` and
`reports/p2-static-y-stress-matrix-report.md`.

The gap P1 left was that its fixtures never produced a **merged mid-screen
batch** — every mid-screen batch was one entry, so `REUSE_LEAD` was sized for a
six-entry merge that no fixture generated. P2 built that fixture (`T6`,
fixture 5: six leaders at Y 60..65, six reusers all at Y 98) and measured it.

**`REUSE_LEAD` stays at 12.** The six-entry merged batch costs **646 cycles** to
its last register write in the worst fine-scroll phase, against a 756-cycle
budget: a margin of **110 cycles**, and it also clears the stricter 693-cycle
sprite-fetch deadline. The budget was argued; it is now measured.

Two structural facts came out of the measurement and belong here rather than in
a report appendix:

- **A merged mid-screen batch never competes with sprite DMA.** The acceptance
  rule requires `Y_i - Y_(i-6) >= 33`, so the batch fires at `Yc-12`, at least
  one line after the last predecessor stopped displaying, and its own sprites
  are not fetched until `Yc-1` — which is the deadline anyway. Badline theft is
  the only variable, which is why the phase sweep is the experiment that matters.
- **Cost is set by badlines inside the CRITICAL PATH, not inside the nominal
  12-line window.** Phases 0, 1 and 6 each have two badlines in the window and
  still cost the minimum, because the second falls after the last register write
  (or, for phase 6, on the entry line before the handler runs). Only phase 7 has
  two inside the path, and it is the only phase that costs 646 rather than 603.
