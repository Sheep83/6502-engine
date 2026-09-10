# P2 — static-Y stress matrix (design, not yet implemented)

Documented now so the test architecture does not accidentally become a
meaningless uniform-spacing benchmark.

## Axis 1 — uniform spacing sweep

Object counts 8 … 16, uniform pitch:

```
40  32  26  24  23  22  21  20  19  18  16  12  8
```

## Axis 2 — vertical phase

Shift the **whole** arrangement by +1 pixel through `0 … 20` (a full sprite
height) so every relationship between sprite Y, sprite DMA, badline phase
(`Y mod 8`) and IRQ line is visited.

## Axis 3 — scroll phase (needs P1)

Repeat with fine scroll pinned to each of `0 … 7`, then free-running, then
across a coarse step and a screen-page flip.

## Axis 4 — non-uniform clustered geometry (the important one)

**Uniform spacing does not stress same-slot reuse.** With six-way round robin,
uniform pitch `S` gives a same-slot separation of `6 × S`, so even `S = 8`
produces a 48-line same-slot gap — comfortably legal and therefore not a test of
anything. The reuse rule is only exercised when the *sixth predecessor* is
close, which requires deliberately clustered layouts:

- six sprites tightly clustered, then a seventh at owner+`MIN_REUSE_GAP` ± 1, ± 2;
- six at Y … Y+5, then six more all sharing one Y (forces a six-entry merged
  batch mid-screen, the case `REUSE_LEAD` is sized for and which the P0 fixtures
  never produce);
- alternating tight/loose pairs so acceptance and rejection interleave;
- a cluster straddling the aperture top and the aperture bottom;
- a cluster straddling a coarse-step boundary.

## Required output form

Statements at this level of determinism:

> "8 sprites at Δ=21, phases 0–20, scroll phases 0–7: clean."
> "At Δ=20 the 9th sprite is rejected by the spacing rule and does not display —
> by design."
> "Δ=22 is clean at scroll phases 0–5 and corrupts at phase 6, offset 3."

Every distinct outcome must be one of: **legal and rendered**, **legal but
conservatively rejected**, **physically unsafe and rejected**, or **renderer
failure**. Only the last is a bug.
