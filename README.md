# 6502-engine

A clean-room **PAL Commodore 64 rendering/multiplexing qualification
laboratory**, written in 6502 assembly for KickAssembler.

This is not a game. It exists to prove one rendering capability at a time, with
deterministic fixtures, before any gameplay is connected to it. It is the
intended foundation for a replacement renderer for the *19656* shooter, whose
existing multiplexer is no longer trusted.

## Toolchain

| | |
|---|---|
| target | Commodore 64, **PAL**, 19,656 cycles/frame |
| CPU | legal NMOS 6502/6510 only |
| assembler | KickAssembler 5.25 |
| emulator | VICE 3.10 (`x64sc`) |

## Architecture direction

```
logical sprites  (pre-sorted by Y in P0)
      |
      v
build complete NEXT schedule          <- main thread, makes every decision
      |
      v
publish (one byte)  ->  swap once at a frame boundary
      |
      v
tiny raster executor consumes the immutable CURRENT schedule
      |
      v
VIC-II
```

Chosen after a study of Armalyte (Dan Phillips), Mike Dailly's Ballistix and
Blood Money write-ups, and Cadaver's Codebase64 material. All three lineages
converge on: one Y-ordered list, sorted once per frame in the main thread, a
complete prepared schedule the IRQ merely consumes, double buffering, a tiny
unrolled executor writing Y first, physical reuse by fixed cycling with a
minimum-gap rejection test, and only a **few** hardware sprites multiplexed.

Two properties are treated as non-negotiable:

- **one renderer subsystem owns gameplay sprite VIC state**;
- **the CURRENT schedule is immutable while the executor runs** — the IRQ never
  reads object state and never makes an allocation decision.

## Physical sprite policy

| hardware sprite | role |
|---|---|
| 0, 1 | reserved for the player (base + overlay). **Disabled in P0.** |
| 2 – 7 | the six gameplay multiplexing slots |

Reuse is round robin over those six, so the first logical sprite that reuses a
slot is **accepted index 6** — the pool is `K = 6`, not 8.

## Checkpoint ladder

See `docs/qualification-ladder.md`. **P0–P4 are implemented. P5–P10 are not.**

## Build

```sh
make            # assemble to build/engine.prg + build/main.vs
make d64        # ...and a bootable build/engine.d64
```

## Run it

```sh
make run        # normal-speed x64sc, no monitor -- the acceptance configuration
make run-d64    # the same, booted from the disk image
```

VICE runs in the **foreground**, so the run lives as long as the terminal or the
VS Code task that started it and stopping that stops the emulator. Append `&` if
you want your prompt back: `make run &`.

Launch through `make` (or the VS Code tasks, which shell out to it) rather than
a bare `x64sc`. `VICE_OPTS` detaches both joystick devices and ignores your
saved `vicerc`: without that, a joystick keyset can bind the host SPACE key to
an emulated joystick, VICE consumes it, and fixture selection goes silently
dead. See §17 of the P0 report.

SPACE cycles the thirty-one fixtures — five from P0/P1, eleven added by P2,
eight by P3 and seven by P4. **M jumps to the first P3 (moving) fixture and S to
the first P4 (sorting) fixture**; SPACE then cycles from there. The
status line shows `FIX / ACC / REU / MRG / UNS` (fixture, accepted, reuse
events, rejected inside the safety margin, rejected as physically unsafe), and
the P2 row (row 22) shows `LOG / MXB / OFF / B6 / PH / PG` (logical sprites
offered, widest mid-screen batch, vertical sweep offset, six-entry batches the
executor has actually run, fine phase, displayed page). The bottom row repeats the active fixture in reverse video
and lights a block while SPACE is actually seen down — if that block never
lights, the machine is not getting the key.

**Fixture 5** is P2's interesting one: six sprites reprogrammed onto a single
raster in one merged batch. **Fixture 23 (`MOTION12`)** is P3's: twelve sprites
all moving in X and Y over the scrolling playfield, six physical slots reused,
some crossing X=255. Press M then SPACE seven times.

(Fixture numbers are shown in **hex** on screen, as `FIX nn` always has been:
fixture 16 reads `10`, fixture 23 reads `17`.)

```sh
make test       # P0 + P1 + P2 + P3 + P4 suites (each owns and reaps its VICE PIDs)
make test-p0    # P0 only: schedule model, acceptance/rejection, timing
make test-p1    # P1 only: scroller, page/pointer ownership, stress run
make test-p2    # P2 only: static-Y stress matrix, merged batches, phase sweep
make test-p3    # P3 only: scripted motion, $D010 / X-MSB, admission threshold
make test-p4    # P4 only: dynamic Y sorter, crossings, identity, capacity
make capture    # one screenshot per fixture into /tmp (an aid, not acceptance)
```

Automated suites launch `x64sc` with **`-console`**: no window, and therefore no
chance of stealing the keyboard focus from whatever else you are doing. This was
measured to be timing-faithful — the executor costs the same cycle counts either
way — and the monitor still renders correct screenshots. `make run` is the one
target that opens a real window, because manual acceptance is a human watching a
real display.

## What P1 adds

A real vertically scrolling, double-buffered playfield under the same five
fixtures. Two screen matrices (`$0400` and `$2800`), fine scroll through every
phase, a coarse row step and a page flip every 8 frames, and **one**
sprite-pointer-table destination per displayed frame — selected by patching a
single operand byte at the frame IRQ, never by writing both tables.

The playfield is a diagnostic surface, not artwork: every row prints its own
world-row number in hex and the letter of the page it was built into, with a
solid bar every fourth row and a `*` walking a diagonal. A stale row, a
duplicated row, a skipped row or a torn page flip is visible without tooling.

## What P0 proves

On a static PAL display, a prepared logical sprite set is displayed
deterministically through the six intended mux slots from a complete immutable
schedule, with:

- physical slot assignment by six-slot round robin, verified against an
  independent model of the rules;
- geometry that cannot be displayed **rejected cleanly** rather than corrupting,
  and separated into *physically unsafe* vs *inside our safety margin*;
- an executor that consults nothing but the schedule;
- a measured worst-case batch cost of **666 cycles**, which is what sets the
  reuse safety margin.

## What P0 does **not** prove

No scrolling. No double-buffered screen pages (P0 has one screen, so exactly one
sprite-pointer destination). No HUD, border opening, player, collision, turrets,
waves or gameplay. No Y sorting — P0 fixtures are pre-sorted deliberately, so
that raster execution is proven before ordering is introduced. No claim about
moving sprites.

## What P2 proves

Exactly what static sprite geometry the six-slot renderer can execute while the
P1 scrolling machine runs, **measured rather than argued**:

- a genuine **six-entry merged mid-screen batch** — six logical sprites
  reprogrammed onto one raster — built, executed and proved two independent
  ways (an in-engine executed-size histogram over 20,000 frames, and a trace
  that counts the sprite writes inside each batch on the machine);
- its cost at **every one of the eight fine-scroll phases**, pinned and verified
  from `$d011` rather than assumed;
- cost by batch size 1 … 6, one controlled variable;
- a vertical sweep of the whole geometry down the visible band;
- exact boundaries: physical (gap 20 / 21) and conservative (gap 32 / 33), each
  a permanent named fixture.

**`REUSE_LEAD` stays at 12.** The worst six-entry batch reaches its last VIC
register write **646 cycles** after IRQ entry against a **756**-cycle budget:
**110 cycles of margin**, 1.75 raster lines. It also clears the stricter
693-cycle sprite-*fetch* deadline. See
`reports/p2-static-y-stress-matrix-report.md`.

Two structural findings worth knowing before touching the renderer:

- **a merged mid-screen batch never competes with sprite DMA.** The acceptance
  rule guarantees the predecessors have stopped displaying before the batch
  fires and the batch's own sprites are not fetched until the deadline, so
  badline theft is the only variable;
- **cost is set by badlines inside the batch's critical path, not inside the
  nominal 12-line window.** Three phases have two badlines in the window and
  still cost the minimum.

## Known limits of the current renderer

- `MIN_REUSE_GAP` is **33 lines** (21 sprite height + 12 measured lead). P2
  measured the six-entry batch it is sized for and found 110 cycles to spare, so
  the constant is now justified by measurement. It remains conservative for
  SMALLER batches — a one-entry batch finishes with 543 cycles unused — and a
  per-batch lead computed by the builder would recover most of that. Deliberately
  left for later: it would make the batch line depend on batch membership, which
  is a schedule-shape change, not a tuning change.
- Batches merge only when two entries need the *same* line.
- `MAX_SCHED` / `MAX_BATCH` are 24; the builder stops adding batches at the cap
  rather than reporting an error.
- All P0 fixture X positions are < 256, so `$D010` is always written as zero.
  The precomputed per-batch `$D010` path exists but is not yet exercised with a
  sprite past X=255.
