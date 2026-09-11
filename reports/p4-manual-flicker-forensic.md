# P4 — manual flicker forensic

**Subject:** visible sprite flicker and corruption on `FIX 19` (CROSS2),
`FIX 1A` (CROSS6), `FIX 1C` (SORTSHAPE) and `FIX 1E` (SORTCAP), reported by
human observation at normal speed while the automated P4 suite was green.

**Result: root cause found, proven, and fixed.** It was not the sorter, not the
mux, not reuse geometry, and not a timing margin. The HUD was overwriting the
live sprite-pointer table.

Status: **fixed and protected by a new regression; awaiting the user's manual
retest** (§18). Human observation remains authoritative and this report does not
claim manual acceptance.

---

## 1. Reproduction status

| fixture | reported | reproduced headlessly | after fix |
|---|---|---|---|
| `FIX 19` CROSS2 | heavy flicker, minor corruption | **yes** — sprite pixels dropped 182 → 87 on 2 frames in 12 | **stable, spread 0 over 30 frames** |
| `FIX 1A` CROSS6 | flicker on the top row only | **yes** — same mechanism | **stable, spread 0 over 20 frames** |
| `FIX 1C` SORTSHAPE | sprites 0–5 flicker; sprite 6 blinks (expected) | **yes** | **stable; only sprite 6's admission blink remains** |
| `FIX 1E` SORTCAP | all rows flicker intermittently | same mechanism, plus its own known overload | §19 |

The corruption was reproduced **headlessly**, frame by frame, by counting
sprite-coloured pixels in captured frames — no reliance on watching a window.

---

## 2. CROSS2 complete frame path

```
main loop pass, paced by frameCounter:
    hudTick        draws ONE HUD row into the page on screen now (round robin)
    motionTick     advances logical X/Y
    sortTick       orders logical IDs by (Y, ID)   -> sortedIDs
    buildSchedule  builds a complete NEXT schedule from the sorted order
    publishSchedule  sets schedPending (one byte)
    regenTick      rebuilds rows of the BACK page
    scrollTick     advances scroll, may flip page, publishes the frame record

frame IRQ at raster 250:
    exFrame        adopt frame record -> $d011, $d018, exPtrStore+2, curPage
                   frameDiagnostics
                   adopt schedule (schedPending) -> schedCurrent
                   $d015 = schedEnable, $d01c = 0
    batch 0        for each entry: $d001 (Y), $d000 (X), $d027 (colour),
                   PTR_x+slot (pointer), then $d010
    exArmFrame     curBatch = 0, arm raster 250

VIC, during the next displayed frame:
    raster ~89     fetches sprite pointer for slot s from (page selected by
                   $d018) + $3f8 + s, then fetches 63 bytes of bitmap
    raster 90-122  displays the two sprites
```

CROSS2 has **two** accepted sprites on HW2/HW3, **one** batch (batch 0), no
reuse, no rejection, no capacity pressure.

## 3. Initial vs later batch architecture

Structurally they are the *same* code — `exBatch` — reached either by falling
through `exFrame` (batch 0) or by a later raster IRQ. The differences are:

| | batch 0 | later batches |
|---|---|---|
| raster | 250, lower border | mid-screen, `Y - REUSE_LEAD` |
| preceded by | frame-record adoption, `frameDiagnostics`, schedule swap, `$d015`, `$d01c` | nothing |
| time until its sprites are fetched | ~117 rasters (next frame) | ~11 rasters |

**That long gap is the whole story.** Batch 0 writes the pointer table at raster
250 and the VIC does not read it until raster ~89 of the *next* frame — with the
entire main-thread pass running in between. A later batch writes its pointers
about 11 rasters before they are fetched, with almost nothing in between.

## 4. Mutable dependencies after CURRENT publication

Audited: **none in the renderer.** The executor reads only `schedCurrent`,
`sched*`, `batch*`, `frameCurrent`, `frame*`, `curBatch`, `curBase`,
`curBatchBase`. It references no logical, motion, sorted, NEXT or fixture state
— asserted at source level over the whole handler body by `test_p4.py`.

The dependency that mattered was not a *read* by the renderer. It was a **write
by someone else into memory the renderer owns**: the sprite-pointer table lives
inside the screen matrix, at `$07f8` (page A) and `$2bf8` (page B), and the main
thread writes the screen matrix constantly.

## 5. Intended vs actual VIC evidence

Sampled at `exDone`, over 40 consecutive CROSS2 frames: `$D015`, `$D010`, and
every mux slot's X, Y, colour and pointer **matched CURRENT exactly**.

> (One apparent mismatch was my own: sprite colour registers `$D027`–`$D02E` are
> 4-bit and read back with the top nibble set, so `$F7` *is* colour 7. Masked.)

So the executor was doing its job perfectly — which is precisely why every
existing test passed. The values were correct **when written** and wrong **when
used**:

```
frame N, raster 250   executor writes $07fa = $80   (correct)
frame N, raster ~300  hudTick draws row 23 and writes $07fa = $a0   (!!)
frame N+1, raster 89  VIC fetches pointer $a0 -> bitmap at $2800
frame N+1, raster 90  sprite displays screen-matrix bytes as a bitmap
frame N+1, raster 250 executor writes $07fa = $80 again, repairing it
```

**Direct proof.** A watchpoint on every byte of both pointer tables
(`$07f8-$07ff`, `$2bf8-$2bff`) recorded which PC stored there:

```
BEFORE THE FIX                     AFTER THE FIX (395 stops)
  $0aaa drawFixRow+11   x64          $15dc exPtrStore+3   x394  (99.7%)
  $15dc exPtrStore+3    x50          $0a19 drawP3Row+2    x1    (artefact*)
```

\* The single `drawP3Row` hit is a monitor PC-attribution artefact, provable by
arithmetic rather than by statistics: row 21 spans `$0748`–`$076f` and its loop
is bounded by `cpy #40`, so it cannot reach `$07f8`.

## 6. Frame-generation coherence

No generation tagging was needed in the end. The failure was not a mixture of
generation N-1 and N state — CURRENT was internally coherent at every sample.
It was **generation N state, correct when written, overwritten by a non-renderer
writer before the VIC consumed it.** Adding a generation tag would have shown
nothing, which is worth recording: the instrumentation that found this was a
*watchpoint on the owned memory*, not a version stamp.

## 7. Initial sprite timing and deadlines

Measured independently of the P2/P3 reuse-batch result, as required:

| | CROSS2 |
|---|---|
| frame IRQ entry raster | 250 (`frameEntryLine`, min = max = 250) |
| CURRENT adoption | within `exFrame`, before any sprite write |
| first HW2/HW3 write | ~raster 257 |
| last critical VIC write (`exWritesDone`) | ~raster 262 |
| VIC pointer fetch for Y≈90 | raster ~89 of the **next** frame |
| margin | ≈ 7,300 cycles |

**Timing was never the problem for batch 0.** The margin is enormous — which is
itself the reason the bug survived: the window between writing the pointers and
the VIC reading them is ~117 rasters long, and that is exactly the window in
which the main thread corrupted them.

## 8. Static control comparison

Not needed as a separate fixture in the end, and the reason is instructive. The
mechanism is independent of sorting: it fires from `hudTick`, on a fixed
round-robin schedule, regardless of whether any sprite moved or any order
changed. The P0/P1/P2 static fixtures are affected identically — they simply
were never manually watched after P4 changed the bottom bar.

The controls that *did* the work were:

- **CROSS2 itself** — two sprites, one batch, no reuse. It isolated the failure
  away from every mux complication, exactly as intended.
- **`exDone` vs `scrollPublish` sampling** — the same state, sampled at two
  different moments in the frame. Coherent at one, corrupt at the other. That
  comparison is what localised the corruption to the main-thread window.

## 9. Crossing-frame identity analysis

Clean. Across the crossing, logical → sorted → schedule → hardware identity held
on every frame, including the exact equal-Y tie:

```
f08  ids=[1,0] slots=[2,3] Y=[95,97] X=[200,120] col=[7,1]
f10  ids=[0,1] slots=[2,3] Y=[96,96] X=[120,200] col=[1,7]   <- tie, ID order
f11  ids=[0,1] slots=[2,3] Y=[95,97] X=[120,200] col=[1,7]
```

At the tie the lower logical ID sorts first, as the documented P4 rule requires,
and each sprite carries its own X and colour onto its new slot. **The sorter was
not implicated at any point.**

## 10. Proven root cause

`fixLineText` — the bottom status bar's text — **lost its terminating zero when
P4 rewrote it** (`"M=P3 KEY"` became `"M=3 S=4"`).

`drawFixRow` drew that row by scanning for the terminator:

```asm
!draw:
    lda fixLineText,y
    beq !digit+          ; stop at the terminating zero
    ora #$80
    sta (scrPtr),y
    iny
    jmp !draw-
```

With no terminator the loop ran off the end of the table, kept storing, and Y
climbed past 39. Row 23's base address is `$0400 + 23*40 = $07b8`, so:

```
y = 39   ->  $07df   last legitimate column
y = 64   ->  $07f8   SPRITE POINTER, slot 0
y = 66   ->  $07fa   SPRITE POINTER, slot 2   <- HW2
y = 67   ->  $07fb   SPRITE POINTER, slot 3   <- HW3
```

It wrote reverse-video label bytes (`$a0`, `$b3`, …) over the live sprite
pointers. `$a0 * 64 = $2800` — the other screen matrix — so the VIC dutifully
fetched 63 bytes of **character data and displayed it as a sprite**, which is
the shredded box in the captured frames.

### Why every observation follows from this

| observation | explanation |
|---|---|
| CROSS2 flickers despite no reuse | its sprites are written **only** by batch 0, so nothing repairs the table before the fetch |
| CROSS6 flickers **only on the top row** | the top row is batch 0; the lower row is a mid-screen reuse batch that rewrites those slots later in the same frame, **repairing the corruption before the fetch** |
| SORTSHAPE: sprites 0–5 flicker | sprites 0–5 are exactly batch 0 |
| flicker is intermittent, not constant | `hudTick` draws one row per frame round robin, so row 23 is drawn once every 5 frames — ~10 Hz |
| automated suite green | every test sampled presentation at `exDone`, immediately after the executor wrote it and long before the HUD overwrote it |

The user's inference — "the initial/top presentation path is implicated, later
reuse looks healthier" — was **exactly right**, and for exactly the reason they
suspected: batch 0 is the batch whose values have to survive longest.

## 11. Smallest failing fixture

`CROSS2` (`FIX 19`) is already the smallest possible reproducer and is retained
unchanged: two sprites, one batch, no reuse. No fixture geometry was altered.

## 12. The fix

`src/main.asm`. Bound the loop by a **length** instead of a terminator, and make
the assembler check the length against the table:

```asm
.const FIXLINE_LEN = 30

drawFixRow:
    ldy #0
!draw:
    lda fixLineText,y
    ora #$80
    sta (scrPtr),y
    iny
    cpy #FIXLINE_LEN
    bne !draw-
...
fixLineTextEnd:
.if (fixLineTextEnd - fixLineText != FIXLINE_LEN) {
    .error "fixLineText length does not match FIXLINE_LEN"
}
.if (FIXLINE_LEN > KEY_COL) {
    .error "fixLineText would overwrite the key-down block"
}
```

Nothing else changed. No sprite was hidden, no geometry altered, no sprite count
reduced, no delay added, no acceptance weakened, no diagnostic suppressed, and
`REUSE_LEAD` was not touched — CROSS2 has no reuse, so a reuse change could
never have been the fix.

## 13. Why this addresses the mechanism

The bug was an **unbounded write** past the end of a screen row into memory the
renderer owns. The fix makes the write bounded by construction. A length cannot
silently go missing the way a terminator did, and if someone edits the text
without updating the length the **build fails** rather than the sprites.

The other HUD rows were audited: `drawStatsRow` scans for a terminator and still
has one; `drawScrollRow`, `drawP2Row` and `drawP3Row` are all bounded by
`cpy #40`. `fixLineText` was the only terminator-scanned row, and is now bounded
too — the class is closed.

## 14. New automated regression

`check_presentation_late()` in `tests/test_p4.py`, run on CROSS2, CROSS6,
SORTSHAPE and SORTSTATIC.

It samples at **`scrollPublish`** — the end of the main-thread pass, after
`hudTick`, `motionTick`, the rebuild and back-page regeneration have all run —
rather than at `exDone`, and asserts:

- the live page's pointer table matches CURRENT for every slot **the executor
  has actually written so far this frame** (using `curBatch`, so a mid-screen
  batch that has not fired yet is not mistaken for corruption);
- `$D015` still equals `schedEnable`;
- sprite colours still match (masked to 4 bits);
- **every mux slot's pointer in *both* tables names a real sprite bitmap.**

That last check is the general one: any byte that is not a bitmap index is
someone else's data, whatever wrote it.

**Verified to fail on the actual mechanism.** The bug was temporarily
reintroduced and the regression caught it immediately on all three fixtures:

```
FAIL CROSS2:    frame 0: $07fc = $a0, not a sprite bitmap pointer
FAIL CROSS6:    frame 0: $2bfa = $a0, not a sprite bitmap pointer
FAIL SORTSHAPE: frame 2: $2bfa = $a0, not a sprite bitmap pointer
```

and passes on the fixed binary (30–40 consecutive frames per fixture). It tests
the *class* — late/stale/incoherent presentation — not the fix's implementation.

### Headless visual verification

Independently of register checks, sprite-coloured pixels were counted in
captured frames:

| fixture | frames | min | max | spread |
|---|---:|---:|---:|---:|
| CROSS2 | 30 | 182 | 182 | **0** |
| CROSS6 | 20 | 2420 | 2420 | **0** |
| SORTSHAPE | 20 | 1328 | 1594 | 266 — **one sprite: sprite 6's expected admission blink** |

Before the fix the same measurement on CROSS2 read `182 182 182 182 87 87 182 …`.

## 15. Executor timing

Unchanged — the fix is in a main-thread HUD routine and does not touch the
executor. Re-measured against the P2 baselines: **delta +0 at every batch size**,
six-entry critical path still **646 cycles**.

## 16. Main-thread timing

The fix makes `drawFixRow` *cheaper* (it no longer writes ~35 bytes past the end
of the row). No measurable change to the preparation span; publication skips
remain zero on production-valid fixtures.

## 17. P0–P4 regression

All five suites against the fixed binary:

| suite | checks passed | failures |
|---|---:|---:|
| `test_p0.py` | 90 | **0** |
| `test_p1.py` | 59 | **0** |
| `test_p2.py` | 117 | **0** |
| `test_p3.py` | 87 | **0** |
| `test_p4.py` | **98** | **0** |
| **total** | **451** | **0** |

P4 gained four checks — the new section 9b, one per fixture:

```
ok  CROSS2:     presentation still matches CURRENT late in the frame, 40 frames
ok  CROSS6:     presentation still matches CURRENT late in the frame, 40 frames
ok  SORTSHAPE:  presentation still matches CURRENT late in the frame, 40 frames
ok  SORTSTATIC: presentation still matches CURRENT late in the frame, 40 frames
```

Everything else is unchanged: sorter correctness, executor critical path
(646 cycles at six entries, delta +0 from P2), scrolling/page/pointer coherence,
and zero publication skips on production-valid fixtures.

## 18. Manual retest instructions

```sh
make run
```

**`FIX 19` — CROSS2 (primary gate).** Press **S**, then SPACE once. Leave running
several minutes. Expect: two boxes, one white showing `0`, one yellow showing
`1`, passing through each other vertically. Required: zero flicker, zero
corruption, no disappearance, no duplicate, no stale numeral or colour, a clean
crossing and a clean equal-Y moment, no horizontal jump, smooth scrolling.

**`FIX 1A` — CROSS6.** Several minutes. Top row and lower row both stable;
identities correct through crossings.

**`FIX 1C` — SORTSHAPE.** Sprites 0–5 stable. Sprite 6 **will** blink on and off
regularly — that is the documented admission behaviour, and `ACC` on row 1 must
agree with whether it is visible.

**`FIX 1E` — SORTCAP.** See §19; judge separately.

## 19. SORTCAP, kept separate

SORTCAP shared the pointer-table corruption and is fixed by the same change.
What remains on it is the **pre-existing, already-documented main-thread
ceiling**: 26 logical sprites re-sorted and rebuilt every frame costs ~85% of a
PAL frame and produces occasional publication skips (a one-frame scroll
stutter). That is a capacity limit reported in the P4 report, not corruption,
and it is deliberately not a gate for P4.

Also still open and unchanged: the **batch-density limit** — the builder has no
rule about how close two consecutive mid-screen batches may be. Neither issue is
implicated in the CROSS2 failure, and neither was touched here.

## 20. VICE process hygiene

`pgrep -fl x64sc` before the work: none. Every probe and suite owns its exact
PID, reaps it in `try/finally`, and verifies it is gone; `-console` throughout,
so no window and no focus theft; no broad `pkill`; no `open -a`. `make run`
remains windowed for the manual retest.

## 21. Disk usage

```
build/                 68K   (engine.prg, main.sym, main.vs)
repo excluding .git   744K
```

Fixed build outputs only, no per-run directories. All probe traces and captured
frames were written to the session scratch area and deleted after use;
`/tmp/6502-engine-*` is empty. The captured PNGs used to prove the pixel counts
were analysed and removed rather than retained, since the failure is now
reproduced by an assertion instead of a picture.

During the final run a non-suite `x64sc` was present (no `-console`, no remote
monitor) — the user's own `make run` window. It was correctly reported as
"other x64sc processes (NOT ours, left alone)" and never touched.

---

## What this says about the harness

The suite was green while a human saw heavy flicker, so the harness was wrong,
and it is worth being precise about *how*:

Every sprite-presentation assertion in P0–P4 sampled at **`exDone`** — the
moment immediately after the executor wrote the values. That proves the executor
is correct. It cannot prove the values survive to be used, and the VIC reads
them up to a whole frame later.

The renderer owns `$D000-$D010`, `$D015`, `$D01C`, `$D027-$D02E` **and the
sprite pointer table** — but the pointer table is the only one of those that
lives in RAM the main thread writes to constantly. Ownership of a register is
enforced by there being one writer; ownership of a *memory location* is not
enforced by anything. That asymmetry is what the new regression now covers.
