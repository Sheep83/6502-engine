# P0 — Clean Renderer Proof

**Verdict: GREEN**, subject to the manual step in §14 that only you can sign off.

Every automated check passes, and I have visually confirmed all five fixtures
render correctly under emulation. The one thing I cannot do for you is the long
normal-speed dwell — by this repository's own rule, automated results do not
close that out.

> **§17 supersedes the launch instructions above.** Manual fixture selection was
> found to be dead: SPACE was being consumed by VICE's joystick emulation before
> the C64 keyboard matrix could see it, because `.vscode/tasks.json` launched
> `x64sc` without `-default` and the saved `vicerc` bound SPACE to joystick port
> 2 fire. Cause, fix and verification are in §17. The renderer was not involved
> and its scheduling and timing are unchanged.

---

## 1. Repository creation and status

Created on GitHub and cloned over SSH to the exact required path.

```
git@github.com:Sheep83/6502-engine.git
        |
        v
/Volumes/SSD/dev/C64/6502-engine
```

* `Sheep83/6502-engine`, public (matching `c64Shooter`'s convention), default
  branch `main`.
* The path did not previously exist; nothing was overwritten.
* `c64Shooter` was **not** touched or restructured.

```
$ git remote -v
origin  git@github.com:Sheep83/6502-engine.git (fetch)
origin  git@github.com:Sheep83/6502-engine.git (push)

$ git status --short --branch
## No commits yet on main
```

**Nothing committed. Nothing pushed.** The worktree is entirely uncommitted, as
instructed.

## 2. Files created

```
AGENTS.md                        permanent working rules
README.md                        purpose, toolchain, ladder, what P0 does/doesn't prove
Makefile                         build / test / run / capture / clean
.gitignore
src/main.asm                     entry, screen, fixture selection, diagnostics
src/renderer.asm                 THE renderer subsystem: schedule builder + raster executor
src/fixtures.asm                 five deterministic logical sprite sets
src/sprites.asm                  sixteen diagnostic numbered sprite bitmaps
tests/test_p0.py                 structural + timing tests, strict VICE PID ownership
tools/capture_p0.py              one screenshot per fixture (an aid, not acceptance)
docs/qualification-ladder.md     P0..P10, and what P1 must decide
docs/p2-static-y-matrix.md       the full P2 stress design, documented now
docs/manual-acceptance.md        the authoritative visual procedure
docs/reuse-inventory.md          19656 reuse / discard inventory
reports/p0-clean-renderer-proof-report.md
build/engine.prg, build/engine.d64, build/main.vs   fixed outputs only
.vscode/tasks.json               VS Code tasks; every one shells out to the Makefile
```

## 3. Reuse / discard inventory

Full version in `docs/reuse-inventory.md`. The headline:

**Reused as knowledge, never as code** — exact PAL discipline; VIC bank-0 map
constraints; the memory-overlap guard lesson (19656's score bitmaps silently
walked onto the enemy sprite pool because their addresses were *derived from a
presentation index*, and every bad address was still 64-byte aligned, so
alignment guards passed); presentation-deadline counters with a *longest
consecutive late run*; framebuffer-vs-model checking; object semantics; stage and
editor data; HUD visual design; collision, hitscan and overheat rules; VICE
automation practice.

**Discarded** — BUILD/LIVE plan pair, `INITIAL_*`, `ASSIGN_*`/`BATCH_*`,
`buildBatchSpriteSchedule`'s adaptive reuse search, `SLOT_FREE_RASTER`, the
current sorter, the current raster batch implementation, the HUD handoff, the
player-layer scheduler, the pointer publication system, and all fallback paths.
No 19656 renderer code was copied.

The measurement that justifies the reset: 19656's object→VIC path had **six**
software representations and two hardware pointer tables, with
**13 writer sites for `$D015`**, 12 for `$D010`, 11 for `$D01C` and 10 for
`$2BF8`.

## 4. Architecture

```
logical sprites (pre-sorted by Y in P0)
   |  buildSchedule        main thread; makes EVERY decision
   v
NEXT schedule buffer
   |  publishSchedule      one byte: schedPending = 1
   v
frame IRQ swaps CURRENT    once, at a frame boundary
   |
   v
raster executor            consumes CURRENT; makes NO decisions
   v
VIC-II
```

The architectural test from the brief — *if game logic stopped immediately after
publication, could the renderer still complete the frame?* — is satisfied by
construction: the executor reads only `schedY/X/Ptr/Col/Slot/Slot2`,
`batchLine/First/Count/D010`, `schedBatches`, `schedEnable` and its own
`curBatch`. It never touches logical sprite arrays, fixture state, ownership
flags or a sorter.

## 5. Schedule memory layout

Two buffers at `$c000`, deliberately **outside VIC bank 0** so schedule state can
never be mistaken for graphics data. 486 bytes total.

```
per entry (indexed [buffer * MAX_SCHED + entry]):
    schedY       sprite Y
    schedX       sprite X low byte
    schedPtr     sprite pointer value
    schedCol     sprite colour
    schedSlot    hardware slot 2..7      (explicit, so it is inspectable)
    schedSlot2   slot * 2                (the $D000/$D001 index, precomputed)

per batch (indexed [buffer * MAX_BATCH + batch]):
    batchLine    raster line this batch fires on
    batchFirst   first entry index
    batchCount   entry count
    batchD010    the COMPLETE $D010 value after this batch

per buffer:  schedBatches, schedEnable, schedEntries
publication: schedCurrent, schedNext, schedPending
```

Two choices worth justifying:

- **`schedSlot2` is precomputed** so the executor needs no arithmetic to index
  `$D000`/`$D001`. One byte of RAM per entry buys a shorter IRQ; the brief
  explicitly prefers that trade.
- **`batchD010` is the complete register value, not a delta.** The builder knows
  the whole frame, so each batch stores the exact `$D010` that should hold after
  it. The executor does a single `sta`, never a read-modify-write of a register
  shared with sprites that are already displaying. This removes an entire class
  of race that the old engine had.

## 6. VIC ownership model

`src/renderer.asm` is the only subsystem that writes gameplay sprite VIC state.
Writer sites in the whole program:

| register | writers | where |
|---|---|---|
| `$D015` | 2 | `installRenderer` (off), frame IRQ (once per frame, from `schedEnable`) |
| `$D01C` | 2 | `main` init, frame IRQ |
| `$D010` | 1 | batch executor, one complete value per batch |
| `$D000-$D00F` | 1 | batch executor |
| `$D027-$D02E` | 1 | batch executor |
| `$07F8+n` | 1 | batch executor |

`main.asm` writes `$D011/$D020/$D021/$D017/$D01B/$D01D` once at startup and never
touches sprite state again.

## 7. Six-slot reuse model

Pool `K = 6`, hardware sprites **2..7**. Sprites 0 and 1 are reserved for the
player and are disabled in P0.

Accepted entry `i` takes slot `2 + (i mod 6)` and reuses the slot of accepted
entry **`i - 6`** — *not* `i - 8`. The first reuse is therefore accepted index 6,
which fixture 1 exists to pin down and which the tests assert explicitly.

The acceptance rule, and why it is not a magic 21:

```
sprite at Y occupies rasters Y .. Y+20        -> slot free from Y+21
batch for entry i fires at Y_i - REUSE_LEAD
    =>  Y_i - Y_(i-6)  >=  SPRITE_HEIGHT + REUSE_LEAD  =  MIN_REUSE_GAP
```

`SPRITE_HEIGHT = 21` is hardware. `REUSE_LEAD = 12` is **ours**, and it is
measured, not assumed — see §10. `MIN_REUSE_GAP = 33`.

Rejections are classified, because "rejected" and "broken" are different things:

| gap | classification |
|---|---|
| `>= 33` | accepted |
| `21 .. 32` | **legal but conservatively rejected** — inside our safety margin |
| `< 21` | **physically unsafe** — the two sprites genuinely overlap on one slot |

## 8. Fixture definitions

| # | Y values | purpose |
|---|---|---|
| 0 | 60, 90, 120, 150, 180, 210 | six sprites, no reuse at all |
| 1 | 55, 82, 109, 136, 163, 190, 217 | seven sprites: the **first reuse**, at accepted index 6 |
| 2 | 55, 67, 79 … 211 (pitch 12, 14 sprites) | eight legal reuse events, nine-batch frame |
| 3 | 60, 62, 64, 66, 68, 70, 72, 74 | tight cluster: entries 6–7 are physically impossible |
| 4 | 60..65, then 80, 81, 92, 93 | boundary: gaps 20 / 21 / 32 / 33 against the slot owner |

Fixture 1's Y values were changed during development: the seventh sprite was
originally at Y=240, in the lower border, so the single thing the fixture exists
to demonstrate was invisible.

Fixture 4's Y values track `MIN_REUSE_GAP` by design; if `REUSE_LEAD` changes
they must move, and that is noted in the source.

## 9. Acceptance / rejection behaviour — measured

Every number below was produced by the 6502 builder and compared against an
**independent Python model** of the documented rules in `tests/test_p0.py`.

| fixture | accepted | reuse | margin-rejected | unsafe-rejected | batches |
|---|---|---|---|---|---|
| 0 | 6 | 0 | 0 | 0 | 1 |
| 1 | 7 | 1 | 0 | 0 | 2 |
| 2 | 14 | 8 | 0 | 0 | 9 |
| 3 | 6 | 0 | 0 | **2** | 1 |
| 4 | 7 | 1 | **2** | **1** | 2 |

Also verified per fixture: entry Y values, the six-slot round-robin slot
assignment, that slots stay within 2..7, that `schedSlot2 == slot * 2`, batch
lines, batch first/count, that every accepted entry is covered by exactly one
batch, and that the schedule fits `MAX_SCHED`/`MAX_BATCH`.

## 10. Timing results

Measured by tracing the executor in VICE (fixture 2, the nine-batch frame).

| | |
|---|---|
| frame IRQ line | 250 (lower border, so batch 0 is programmed before the display) |
| batch IRQ lines observed | 115, 127, 139, 151, 163, 175, 187, 199 — exactly `Y − 12` |
| handler cost, single-entry batch | 232 – 300 cycles (max **4.8 raster lines**) |
| handler cost, six-entry frame batch | **666 cycles** (10.6 raster lines) |
| `REUSE_LEAD` budget | 12 lines = 756 cycles |
| margin at worst case | 90 cycles |
| logical sprites / physical slots / reuse events | 14 / 6 / 8 |

**`REUSE_LEAD` began as a guess of 3 lines and the test rejected it.** The
executor is only ~90 cycles of 6502; the rest is VIC cycle theft — a badline plus
sprite DMA on a line with six sprites active. That is precisely why this number
has to be measured against real VIC timing rather than counted from a listing,
and it is the single most useful thing P0 established.

The budget is sized for a **six-entry** batch even though the P0 fixtures only
produce one-entry batches mid-screen, because the builder *can* merge six entries
onto one line (six accepted sprites sharing a Y, with distant slot owners).

### VIC-II timing assumptions, stated explicitly

- a sprite with `$D001 = Y` displays on rasters `Y .. Y+20`; its slot is free
  from `Y+21`;
- `$D001` must be written before the beam reaches `Y`, which is why the executor
  writes **Y first** and everything else after — Y is the only timing-critical
  write, the rest is cosmetic;
- badlines steal up to ~43 cycles and sprite DMA steals further cycles per active
  sprite per line, so a batch's *wall-clock* cost is load-dependent even though
  its instruction count is fixed;
- a raster IRQ armed at or before the current `$D012` will not fire until the next
  frame, so the executor checks `$D012` after arming and falls straight into the
  next batch if it is already late.

## 11. Automated test results

```
=== 0. build artefacts present ===                     2/2 ok
=== 1. static memory-layout invariants ===             3/3 ok
        schedule state 486 bytes; sprites 64-byte aligned at $2000, end $2400
=== 2. schedule builder vs independent model ===      70/70 ok  (5 fixtures x 14 checks)
        first reuse is accepted index 6 (six-slot, not eight-slot) -- entry 6 -> hw slot 2
=== 3. executor timing ===                             3/3 ok
=== 4. cleanup ===                                     2/2 ok
=== ALL PASS ===
```

Run three consecutive times to confirm the harness itself is deterministic.

Build is clean with KickAssembler 5.25, no warnings; memory map:

```
$0810-$0981 main          $1000-$1215 schedule builder
$1500-$1619 raster executor   $1800-$1900 fixtures
$2000-$23ff diagnostic sprites    $c000-$c1f0 schedule buffers
```

## 12. VICE cleanup verification

```
before any work:   pgrep -fl x64sc  ->  none running
after the suite:   pgrep -fl x64sc  ->  none running
```

Every launch is owned by a `Vice` object that records the PID, prints it, and
terminates + `wait`s it in a `finally` block — proven to work, since it reaped
cleanly on each of the exceptions raised during development. No broad `pkill` is
used anywhere. All launches are direct background `Popen`, never `open -a`, and
never steal focus.

## 13. Disk usage

```
build/   56K   (p0.prg, main.vs, main.sym only — no per-run directories)
repo    228K   total
scratch   0    /tmp/6502-engine-p0 removed by the test; screenshots deleted
```

## 14. Manual visual test — your step

Full procedure in `docs/manual-acceptance.md`.

```sh
cd /Volumes/SSD/dev/C64/6502-engine
make run          # normal speed, no monitor, no warp
```

SPACE cycles the fixtures. **Dwell at least 30 seconds on each** — the failure
mode this whole effort exists to catch is intermittent.

Each sprite is a hollow box containing **its logical index in hex**, in its own
colour. If sprite `B` ever shows a `5`, or two boxes show the same numeral, or a
box flickers or tears, that is a renderer failure. Fixtures 3 and 4 showing
*fewer* sprites than they list is correct.

I have inspected captured frames of all five fixtures and they are correct:
fixture 2 renders all fourteen sprites `0`–`D` as a clean multi-coloured cascade
through six hardware slots; fixture 3 shows exactly six clustered sprites with
`UNS 02`; fixture 4 shows the six clustered sprites plus a single `9` — the
accepted boundary candidate — with `MRG 02  UNS 01`. That is emulator evidence,
not the long dwell.

## 15. Known limitations

- `MIN_REUSE_GAP = 33` is conservative: sized for a six-entry batch. A per-batch
  lead computed by the builder (which knows each batch's count) would recover
  most of it. Deliberately deferred — P0 is meant to be boring.
- Batches merge only on an exact line match, not within a window.
- `MAX_SCHED`/`MAX_BATCH` are 24; on overflow the builder stops adding batches
  rather than reporting an error. Guarded by test, not by the engine.
- All fixture X values are < 256, so the precomputed `$D010` path always writes
  zero. It is implemented but not yet exercised with a sprite past X=255.
- P0 does no sorting: the fixture lists are pre-sorted by design.
- One screen page, so exactly one sprite-pointer destination. The hard case
  arrives at P1.
- The harness cannot observe a freely-running **non-warp** machine, because any
  monitor command halts the emulator. Automated capture therefore runs under
  warp, which changes only how much emulated time passes per monitor round trip.
  This is exactly why the manual step is not optional.

## 16. Recommendation for P1

**Scope:** add the scrolling double-buffered playfield to the P0 fixtures.
Nothing else. Keep all five P0 fixtures runnable and passing.

**The one design decision P1 must make**, and it should be made deliberately
rather than inherited: with two screen pages there are two sprite-pointer tables
(`$07f8` and `$2bf8`). Do **not** adopt "write both every frame". The model to
implement is:

```
frame chooses the active screen
    -> renderer establishes ONE pointer-table destination for that frame
    -> every sprite pointer write that frame targets that page
```

via a patched store address in the executor, or two tiny executor paths. The
schedule already carries everything else; the destination is simply one more
thing the *builder* decides and the executor obeys.

**Add to the test suite at P1:** that the pointer destination matches the page
`$D018` actually selects, on every frame, across flips; and that a coarse flip
never lands between a batch's Y write and its pointer write.

**Do not** start P2's stress matrix until P1's fixtures pass both automatically
and on a long non-warp dwell. The design is already written down in
`docs/p2-static-y-matrix.md`, including the point that uniform spacing alone is a
meaningless benchmark for six-way round robin — same-slot separation is `6 × S`,
so the reuse rule is only exercised by deliberately clustered geometry.

## 17. Manual fixture selection was dead — cause and fix

Reported after the report above was written: `make run` launches correctly but
pressing SPACE does not cycle the fixtures. **Reproduced, diagnosed and fixed.
The renderer was not involved and nothing in its scheduling or timing changed.**

### What it was not

The 6502 keyboard scan was correct and always had been. Row 7 is selected by
writing `$7f` to `$DC00`, and SPACE is column bit 4 of `$DC01`; the edge detect
against `prevSpace` was right too. Driven directly, the loop cycled every
fixture. The CIA was configured as expected at `mainLoop`:

```
DDRA $dc02 = $ff     DDRB $dc03 = $00     PRA $dc00 = $7f     $01 = $35
```

### What it was

**The host SPACE key never reached the emulated keyboard at all.** It was being
consumed by VICE's joystick emulation before the C64 matrix could see it.

`~/.config/vice/vicerc` on this machine contains:

```
KeySet1Fire=32        <- keysym 32 is SPACE
JoyDevice1=1          <- native port 1 = Numpad
JoyDevice2=2          <- native port 2 = Keyset 1
```

Read live from the running emulator, via the monitor, in the configuration the
VS Code task launches: `JoyDevice2=2`, `KeySet1Fire=32`.

So SPACE was bound to the fire button of the joystick in **control port 2** —
and control port 2 is wired to CIA1 **Port A (`$DC00`)** bit 4, which is the
*row-select* register the scan writes, not the column register (`$DC01`) it
reads. The press therefore could not appear where the scan was looking. Measured
with SPACE held on the failing configuration: **every** matrix row reads `$ff`
and the fixture index never moves.

### Why `make run` looked guilty

It was not `make run` that was failing. `.vscode/tasks.json` carried its own
hand-written toolchain, inherited wholesale from the `c64Shooter` project:

```
build -o build/shooter.prg ... && c1541 -format "19656,01" d64 build/shooter.d64
x64sc "${workspaceFolder}/build/shooter.prg"
```

It compiled *this* repository's `src/main.asm` to `build/shooter.prg`, and
launched `x64sc` with **no `-default`** — so the saved `vicerc` above applied in
full. The VICE process alive at the start of this investigation was exactly
that: `x64sc /Volumes/SSD/dev/C64/6502-engine/build/shooter.prg`. `make run`
does pass `-default`, and under `-default` the binding is absent
(`JoyDevice2=1`, `KeySet1Fire=0`) and SPACE works.

The root cause is therefore **two copies of the launch command that drifted
apart**, and a keyboard scan with no way to report that it was receiving nothing.

### The fix

1. **One definition of the launch, in the Makefile.** `VICE_OPTS` is
   `-default +saveres -pal -joydev1 0 -joydev2 0 +keyset`. Both joystick devices
   are detached, so nothing can intercept a host key: port 1 is CIA1 `$DC01` and
   port 2 is CIA1 `$DC00`, the two registers the scan uses. `+saveres` is a
   safety measure in its own right — a `-default` run with the user's
   `SaveResourcesOnExit=1` would otherwise write factory settings back over
   their own `vicerc` on exit.
2. **`.vscode/tasks.json` now shells out to `make`** — build, d64, run, run-d64,
   test, clean. It can no longer drift, because it no longer holds a command
   line of its own.
3. **Build outputs renamed** to `build/engine.prg`, with `make d64` producing
   `build/engine.d64` (`make run-d64` boots it). The stale `shooter.prg`,
   `shooter.d64` and `p0.prg` were deleted; `build/` again holds only the
   current binary, disk image and symbols.
4. **The failure can no longer be silent.** The bottom row now reads
   `FIXTURE n  SPACE = NEXT   KEY #` in reverse video, at raster ~242 — below
   the lowest sprite any fixture places (Y 217 + 21 = 238), so it is never
   covered. The block after `KEY` fills only while the scan actually sees SPACE
   down. If it never lights, the machine is not receiving the key, and the
   renderer is not the suspect.
5. **Test process ownership fixed.** The suite's final check matched `pgrep`
   output against the string `6502-engine`, which also matches any manual VICE
   session the user has open on this project — it reported the user's own
   session as a leaked test process. Ownership is now by recorded PID, and other
   `x64sc` processes are listed explicitly as *not ours*.
6. **Deterministic startup.** `prevNext` now initialises to `1` (HELD), so a
   press only counts after a release. VICE's autostart drives the keyboard
   matrix to type `RUN`, and one launch was observed coming up on fixture 3;
   this makes startup independent of whatever the host leaves in the matrix.
7. **The run targets no longer background VICE.** Follow-up: with the tasks
   wired to the Makefile, "Run in VICE" still appeared to do nothing. `make run`
   ended in `&`, so make returned the instant it had forked; VS Code treated the
   task as finished and killed its process tree, taking the emulator with it.
   `run` and `run-d64` now hold VICE in the **foreground**, so the task lives
   exactly as long as the emulator and ending the task stops it cleanly — the
   same PID ownership this repository asks for everywhere else. From a terminal,
   background it yourself with `make run &`. Verified: the emulator comes up
   while the command is still running, and is gone once the command is stopped.

### Rejected

Reading joystick port 2 fire as a second input source. It was implemented and
measured: on the failing configuration the fire line is **not** asserted either
— the key is simply swallowed — so it fixed nothing, and it could not be
verified in any configuration available here. It was removed rather than shipped
unproven. The scan stays a plain keyboard scan.

### Verification

**Real host SPACE presses, non-warp, `make run` options.** Each press advances
exactly one fixture, and the *screen RAM* — status-line `FIX` field and
bottom-bar digit — is read back and checked against the schedule counters:

```
step  5: fixtureIndex=1  FIX='01'  bar='FIXTURE 1'  ACC=7  REU=1 MRG=0 UNS=0  ok
step  6: fixtureIndex=2  FIX='02'  bar='FIXTURE 2'  ACC=14 REU=8 MRG=0 UNS=0  ok
step  7: fixtureIndex=3  FIX='03'  bar='FIXTURE 3'  ACC=6  REU=0 MRG=0 UNS=2  ok
step  8: fixtureIndex=4  FIX='04'  bar='FIXTURE 4'  ACC=7  REU=1 MRG=2 UNS=1  ok
step  9: fixtureIndex=0  FIX='00'  bar='FIXTURE 0'  ACC=6  REU=0 MRG=0 UNS=0  ok
step 10: fixtureIndex=1  FIX='01'  bar='FIXTURE 1'  ACC=7  REU=1 MRG=0 UNS=0  ok
RESULT: all five fixtures cycle, screen agrees with schedule
```

**Before/after on the same binary.** Under the saved `vicerc`, seven real SPACE
presses give `0, 0, 0, 0, 0, 0, 0`. With the joysticks detached, the same test
gives `1, 2, 3, 4, 0, 1, 2`.

**Press duration is not a factor** — holds from 5 ms to 400 ms are all detected,
so this was never a polling-rate problem.

**Two full laps, deterministic.** Driving CIA1 PB4 directly (no host keyboard,
so no window-focus race) gives eleven consecutive presses, `PASS` on every one,
including the `KEY` block reading `$a0` while held and `$20` once released.

**The P0 automated suite passes in full and unchanged in substance:**
`=== ALL PASS ===`. Worst executor batch cost is still **666 cycles** against
the 756-cycle `REUSE_LEAD` budget, and the frame IRQ still fires on line 250 —
the renderer was not touched.

**Process ownership.** Every VICE launched during this work was tracked by PID
and reaped. The user's own manual session (`pid 84651`) was identified as not
ours and left running throughout; the suite now reports it explicitly:

```
launched and reaped: [89004, 89029]
other x64sc processes (NOT ours, left alone): {84651: '.../build/shooter.prg'}
```

### Still yours to sign off

§14 is unchanged: the long normal-speed dwell on each fixture is the
authoritative test and automated results do not close it out. What §17 fixes is
that you can now actually *reach* all five fixtures in order to do it.

---

## Appendix — the Armalyte source you supplied

You gave me Dan Phillips' actual multiplexer and sort, which my previous
architecture study could only describe second-hand (Lemon64 returns 403 to
automated fetches). Two things are worth recording, one of which **corrects that
earlier report**.

**It confirms the six-slot pool.** The mux writes `$D004/$D005` … `$D00E/$D00F`
and colours `$D029`…`$D02E` — that is hardware sprites **2..7**, with 0 and 1
reserved, exactly the policy adopted here. `CS` cycles 0..5. Twenty logical
sprites over six physical.

**Its reuse test is a live comparison against the hardware register**, not a
table:

```
        SEC
TE0     LDA $D012
        SBC #22
        SBC $D005        ; the Y currently programmed into this physical sprite
        BCS IT0          ; safe: beam is >= 22 lines past it
        CMP #253
        BCS TE0          ; close: spin
        JMP INTO         ; far: schedule a later IRQ
```

So Armalyte's margin is `21 + 1 = 22` lines, and it *polls* when close rather
than always taking an interrupt — a hybrid this engine deliberately does not copy,
because a fully precomputed schedule is easier to inspect. Our `MIN_REUSE_GAP` of
33 is more conservative than Armalyte's 22 because our batch does more work per
IRQ; a future per-batch lead would close most of that gap.

**The correction:** I previously reported, from search fragments, that Armalyte
used an Ocean-style *persistent* order array. The real source shows otherwise —
`YSORT` is a **stack-based distribution sort**, rebuilt from scratch every frame:
it sets `S = Y/2` to address the stack page as a bucket array, probes upward with
`PLA/BPL` for a free slot, and pushes the sprite index there; a second pass pops
the page back out in order into `YORDER`. That is O(N), not incremental, and it
is a different algorithm from the one Cadaver recommends. P4 should treat both as
candidates rather than assuming the Ocean sort is what Armalyte did.
