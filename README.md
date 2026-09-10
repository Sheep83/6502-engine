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

See `docs/qualification-ladder.md`. **P0 is implemented. P1–P10 are not.**

## Build

```sh
make            # assemble to build/engine.prg + build/main.vs
make d64        # ...and a bootable build/engine.d64
```

## Run P0

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

SPACE cycles the five fixtures. The status line shows
`FIX / ACC / REU / MRG / UNS` (fixture, accepted, reuse events, rejected inside
the safety margin, rejected as physically unsafe). The bottom row repeats the
active fixture in reverse video and lights a block while SPACE is actually seen
down — if that block never lights, the machine is not getting the key.

```sh
make test       # structural + timing tests (owns and reaps its VICE PIDs)
make capture    # one screenshot per fixture into /tmp (an aid, not acceptance)
```

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

## Known limits of the current renderer

- `MIN_REUSE_GAP` is **33 lines** (21 sprite height + 12 measured lead). That is
  conservative: it is sized for a six-entry batch even though the P0 fixtures
  only ever produce one-entry batches mid-screen. A per-batch lead computed by
  the builder would recover most of it, and is deliberately left for later.
- Batches merge only when two entries need the *same* line.
- `MAX_SCHED` / `MAX_BATCH` are 24; the builder stops adding batches at the cap
  rather than reporting an error.
- All P0 fixture X positions are < 256, so `$D010` is always written as zero.
  The precomputed per-batch `$D010` path exists but is not yet exercised with a
  sprite past X=255.
