# P2 — static-Y stress matrix

**Implemented.** Measured results are in
`reports/p2-static-y-stress-matrix-report.md`; this document is the design and
the reasoning behind the axes, kept so the test architecture does not
accidentally become a meaningless uniform-spacing benchmark.

## The headline

`REUSE_LEAD` was sized for a six-entry merged mid-screen batch that no P0 or P1
fixture ever produced. P2 built that fixture, executed it, and measured it.

| | |
|---|---|
| worst six-entry batch, to last VIC register write | **646 cycles** |
| budget (`REUSE_LEAD * 63`) | **756 cycles** |
| margin | **+110 cycles** (1.75 raster lines) |
| stricter sprite-*fetch* deadline (`11 * 63`) | 693 cycles — also met |
| verdict | **`REUSE_LEAD` stays at 12** |

## Axis 1 — uniform spacing sweep

Spacings `30 24 22 21 20 18 16 12`, starting at Y 55 and filling the visible
band.

**Every one is fully accepted, and that is the finding.** Six-way round robin
means uniform pitch `S` gives a same-slot separation of `6 x S`, so even `S = 6`
clears the 33-line gap. The uniform axis cannot exercise the reuse rule at all;
it exercises batch *density* (`S = 12` gives ten batches a frame) and nothing
else. It is retained precisely so that claim is tested rather than assumed.

## Axis 2 — vertical position

The whole arrangement is shifted down one raster at a time by
`fixtureYOffset`, which `loadFixture` adds to every Y. The structural sweep runs
offsets 0…120 — the merged batch walks from raster 86 to raster 206 — and every
offset is checked field by field against the model. A subset is also timed.

Result: vertical position barely matters. Across the whole band the worst
critical path varies only between 639 and 646 cycles, because the badline
*relationship* is set by the phase, not by the absolute raster.

## Axis 3 — scroll phase

`pinFine` / `pinFineValue` in `scroll.asm` hold the fine scroll at a chosen
YSCROLL while everything else runs normally. The test verifies the phase it
asked for by reading **`$d011` on the running machine**, not by trusting the
poke.

Holding the phase necessarily suspends the coarse step and the page flip —
those *are* the fine-scroll wrap — which is exactly why natural scrolling is
then restored and the same geometry re-proven across ~20,000 frames of real
coarse steps and page flips with every P1 coherence counter still at zero.

## Axis 4 — non-uniform clustered geometry (the important one)

The reuse rule is only exercised when the *sixth predecessor* is close. The
geometry is derived from the rule rather than guessed:

```
six leaders at Y0 .. Y0+5, then six reusers all sharing Yc.
The binding pair is the LAST reuser against the LAST leader:
    Yc - (Y0 + 5) >= MIN_REUSE_GAP   ->   Yc >= Y0 + 38
With Y0 = 60 that is Yc = 98.
```

So `Yc = 98` is two things at once: the smallest Yc that merges six entries into
one batch, and the exact conservative boundary for the binding pair. One raster
lower and it is a five-entry batch — which is what fixtures 6…10 step through,
giving a batch-size ladder with one controlled variable.

## Two structural findings

**A merged mid-screen batch never competes with sprite DMA.** The acceptance
rule forces `batch line = Yc-12 >= predecessor_end + 1`, and the batch's own
sprites are not fetched until `Yc-1 = batch line + 11` — which is the deadline
anyway. The window is structurally DMA-free, so **badline theft is the only
variable**, and the phase sweep is the experiment that matters.

**Cost is a step function of badlines inside the CRITICAL PATH**, not inside the
nominal 12-line window. Phases 0, 1 and 6 each have two badlines in the window
and still cost the minimum: for 0 and 1 the second falls past the last register
write, and for 6 it falls on the entry line, where it is absorbed into interrupt
latency ahead of the first traced instruction. Only phase 7 has two genuinely
inside the path, and it alone costs 646 rather than 603 — a difference of 43
cycles, exactly one badline.

An earlier version of the suite asserted the opposite (that in-*window* badline
count predicts cost). The measurement refuted it and the check was rewritten
around what the machine shows.

## Classification

Every case ends as exactly one of: **legal and rendered**, **legal but
conservatively rejected**, **physically unsafe and rejected**, **renderer
failure**, or **harness failure**. Only the last two are bugs, and conservative
rejection is never conflated with physical impossibility.

Across 145 cases: 1682 rendered, 4 conservatively rejected, 4 physically unsafe
and rejected, **0 renderer failures**.

## Permanent named fixtures

Boundary cases are fixtures in the binary, not sweep coordinates someone has to
recompute:

| # | name | what it pins down |
|---|---|---|
| 5 | `T6` | the six-entry merged batch |
| 6–10 | `T5`…`T1` | the batch-size ladder, one controlled variable |
| 11 | `SPLIT` | batch-merge boundary: Y and Y+1 must **not** merge |
| 12 | `BNDPHYS` | gap 20 unsafe / gap 21 physically legal but rejected |
| 13 | `BNDCONS` | gap 32 rejected / gap 33 accepted |
| 14 | `T6X3` | three six-entry merged batches in one frame, at `MAX_SCHED` |
| 15 | `WORST` | the worst measured legal geometry, frozen at offset 8 |

Fixtures 12 and 13 are written in terms of `SPRITE_HEIGHT` and `MIN_REUSE_GAP`,
so they track the constants automatically if `REUSE_LEAD` is ever changed.
