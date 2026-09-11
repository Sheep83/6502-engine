# FIX 16 / MAXCAP — visual corruption forensic

**Verdict: GREEN.** The corruption reproduces, is fully explained, and is fixed
by a six-cycle change in one place. It was not a bad pointer, not a bad
schedule, and not the batch-density limit P4 reported. It was the raster
interrupt being acknowledged at the wrong moment, which let the **frame
transaction execute at raster 182 instead of 250** on about 1% of frames.

---

## 1. The observation, reproduced

`FIXTURE 16` (hex) = decimal 22 = P3 `MAXCAP`: 30 logical sprites, 24 accepted,
6 overflow, 19 batches. The human report was severe visible corruption at normal
speed while every automated check was green.

Reproduced mechanically. Frames were captured at `exWritesDone` with
`curBatch == 0` — raster ~262, below the display window, so the whole visible
frame is complete and a capture cannot tear — and every accepted sprite was
compared pixel for pixel against the bitmap its own schedule entry points at:

```
frames checked: 40
frames with any sprite not matching its schedule entry: 2/40   (5%)
  frame 17: acc21(slot5,Y176) -28/254px; acc22(slot6,Y182) -20/266px
  frame 18: acc1..acc12 -- 12 sprites, 100% of their pixels, entirely absent
```

The corrupted frame is unambiguous, and it is **not** a capture artefact: the
character playfield renders completely and correctly across the whole screen,
HUD rows included. Only sprites are missing, and only the ones above a raster.

## 2. The two candidate explanations, and which one died

The brief asks to distinguish *"the renderer writes a good pointer and something
corrupts it"* from *"the builder produces a bad pointer that the renderer writes
faithfully."*

**Both are wrong.** The builder is correct and the renderer is correct.

| checked | result |
|---|---|
| all 24 accepted pointers | `$80`–`$8F` then wrapping `$80`–`$87`; every one resolves inside `$2000`–`$23FF` |
| bitmap pool `$2000-$23FF` | byte-identical before and after an 8-second run — nothing writes it |
| per-batch VIC state vs. the model | X, Y and pointer for every slot after every one of the 19 batches: **0 mismatches** |
| `$D015` enable mask | matches `schedEnable` |
| batches executed per frame | exactly 19, on **249/249** frames — none skipped, none repeated |
| schedule buffer bounds | build never writes outside its own buffer (existing canary, section 9) |
| historical `logPtr` wrap (ids 16–23) | correct; the P3 fix holds |

A still frame is likewise correct: with the calibration solved rather than
assumed (all 24 sprites vote unanimously for the same offset), **23 of 24
sprites are pixel-perfect**, and the 24th differs only in its top rows, which
the top border clips because the engine runs RSEL=0 for scrolling.

So the engine writes the right values, to the right registers, from the right
schedule. What was wrong was **when**.

## 3. Root cause

`irqHandler` acknowledges the raster interrupt **once, on entry**
(`src/renderer.asm:611`):

```asm
irqHandler:
    pha / txa / pha / tya / pha
    lda #$01
    sta $d019            // acknowledge the raster IRQ
```

and then, several raster lines later, arms the next one:

```asm
exArm:
    sta $d012
    cmp $d012
    bcc exLate
    jmp exDone
```

A batch costs about five raster lines. MAXCAP arms its batches **six** lines
apart. So the beam routinely crosses the freshly armed line *while the handler
is still running* — after the acknowledge. The VIC latches that interrupt and
nothing ever clears it, so the `rti` re-enters the handler immediately.

Measured, before the fix:

```
FIX 16  raster IRQ still latched at the rti: 346/500 handler exits (69.2%)
FIX 17  raster IRQ still latched at the rti:   0/500 handler exits  (0.0%)
```

Mid-frame this is harmless — the next batch simply runs a line late, which is
the whole `statLate` population. **At the end of the frame it is destructive.**
`exArmFrame` has already set `curBatch = 0` and armed line 250, so the spurious
re-entry runs `exFrame` — the entire frame transaction — in the middle of the
visible display:

```
FIX 16  frameEntryLine histogram: {182: 1, 183: 3, 250: 396}   4/400 frames (1.0%)
FIX 17  frameEntryLine histogram: {250: 400}                   0/400 frames (0.0%)
```

Raster 182 is exactly where batch 18 — armed at line 176 — finishes.

On such a frame `$D011` (fine scroll), `$D018` (screen page), the pointer-table
destination, `$D015` and batch 0 are all rewritten at raster 182. Batch 0
programs slots 2–7 with accepted entries 0–5, whose Y values (50–80) the beam
passed a hundred lines ago, so they never appear. `exLate` then chases every
batch whose line is behind the beam, burning through them in one burst:

```
maxLateRun = 13      <-->      13 sprites missing from the corrupted frame
```

Entries 0–12 vanish; entries 13–23 render correctly. That is precisely the
captured frame. At 50 Hz, 1% of frames is an event roughly every two seconds —
plainly visible to a human, and almost never caught by a single screenshot.

## 4. Why every test was green

Every check P0–P4 makes asks **what** the executor wrote, sampled at `exDone`
or at `scrollPublish`. All of those answers were correct, on every frame,
including corrupted ones — the values really were right. Nothing asked **at
what raster the frame transaction ran**, which was the only thing that was
wrong. `check_presentation_late()`, added for the P4 flicker forensic, is
raster-aware but compares against `curBatch`, so a frame transaction that ran
early is self-consistent with it.

The invariant was even written down and never checked — `src/renderer.asm:153`,
on `frameEntryLine`: *"Must always be FRAME_IRQ_LINE."*

## 5. The fix

`src/renderer.asm`, `exArm`. Six cycles, one place:

```asm
exArm:
    ldx #$01
    stx $d019        // acknowledge BEFORE arming
    sta $d012
    cmp $d012
    bcc exLate
    beq exLate       // equality counts as late
    jmp exDone
```

Three properties make this correct:

- **Acknowledge before the arm, not after.** `$D012` still holds the line this
  handler was entered for and the beam is already past it, so nothing can latch
  between the two stores. Every latch after the arm is a genuine crossing of the
  *new* line and is left alone for the `rti` to service.
- **Equality counts as late.** The VIC raises when the counter *becomes* equal
  to `$D012`, at the start of the line; arming the line the beam is already on
  raises nothing, ever. This was found the hard way — an earlier version of the
  fix acknowledged *after* arming and kept the original `bcc`, which silently
  dropped any batch armed on the current line. `statLate` read 0, `maxLateRun`
  read 0, `frameEntryLine` read 250 — every instrument clean — while the picture
  was worse than before. It is recorded here because the failure was invisible
  to exactly the instruments that were meant to catch it.
- **X is free.** It holds `schedCurrent`, dead from this point; `exDone` restores
  it from the stack and `exBatch` reloads it. Using X keeps A live for the
  comparison.

### Measured effect

| | before | after |
|---|---|---|
| `frameEntryLine != 250` | 4/400 frames (1.0%) | **0/400** |
| corrupted frames (pixel diff) | 2/40 (5%) | **0/40** |
| batches executed per frame | 19 (correct) | 19 (correct) |
| `statLate` / `maxLateRun` | 255 / 13 | 255 / 12 |

`statLate` staying saturated is the honest result, not a leftover fault: those
are real crossings of an armed line by a handler that is still running, and
chasing them is the intended recovery. What changed is that the chase can no
longer be entered by a stale latch with `curBatch` already wrapped to 0.

## 6. A P4 finding this corrects

The P4 report attributed this chaining to a **batch-density limit** — batches
armed closer together than a batch costs to execute — and deliberately left it
unfixed for a later checkpoint. That diagnosis was wrong in its mechanism.
Density is what *exposes* the bug (it is why MAXCAP and the first `SORTCAP`
draft trip it and sparse fixtures never do), but the fault was the unacknowledged
latch, not the spacing. MAXCAP now runs 19 batches at 6-raster spacing with a
pixel-perfect display. **No admission rule for batch spacing is needed, and none
was added.** `MIN_REUSE_GAP`, `REUSE_LEAD` and `MAX_SCHED` are unchanged; the
MAXCAP sprite count is unchanged; no pointer is clamped anywhere.

## 7. Regression

`tests/test_p4.py`, new section **9c**, `check_frame_transaction_raster()`:
`frameEntryLine == FRAME_IRQ_LINE` on every frame, over 150 frames, on MAXCAP
(the dense P3 case) and SORTCAP (the P4 equivalent). `frameEntryLine` is sampled
by the handler itself into RAM, so the check does not race the emulator.

Proven to catch the fault, by reverting the fix and rebuilding:

```
PRE-FIX   FAIL MAXCAP: ... -- frame transaction entered at raster 183
          ok   SORTCAP: ... -- 150 frames, every one entered at 250
POST-FIX  ok   MAXCAP:  ... -- 150 frames, every one entered at 250
          ok   SORTCAP: ... -- 150 frames, every one entered at 250
```

SORTCAP passes either way — its four batches are far apart. That is why the
check runs on MAXCAP: **the dense fixture is the one with detection power**, and
a spacing-only fixture would have hidden this bug exactly as it was hidden
before.

The test deliberately does **not** assert that `$D019` is clear at the `rti`.
Under the fix it frequently is not — about a third of MAXCAP's handler exits —
and that is correct: it is the next batch's own interrupt. Asserting it away
would re-break the engine.

## 8. One thing the fix exposed: a latent wrap in the P2 suite

The full P0–P4 run failed once, on P2:

```
FAIL T6X3: six-entry batches kept executing across flips -- 516
```

It looked like the fix had destroyed mid-screen batch execution. It had not.
`batchSizeHist` is sixteen bits per size; section 11 runs for twenty seconds of
warp, which is **not a fixed number of frames**; and T6X3 executes three
mid-screen batches per frame. Doing the arithmetic against the frame count the
same run reported:

| build | frames | × 3 | mod 2^16 | observed |
|---|---|---|---|---|
| pre-fix | 18,821 | 56,463 | 56,463 | 56,461 |
| post-fix | 22,018 | 66,054 | **518** | 516 |

The fixed build got 17% further in the same twenty seconds and crossed the
counter boundary. It executed **more** six-entry batches, not fewer — the
assertion was a bare floor (`hist[6] > 1000`) and read a wrapped 518 as
catastrophe.

Corrected in `tests/test_p2.py` to compare against what the frame count says the
value must be, modulo the counter width. That is wrap-proof, and it is a
strictly stronger statement than a floor: it now asserts that **every frame ran
every mid-screen batch**, which is what "kept executing across flips" was always
meant to mean.

Worth stating plainly: this is the second time in this investigation that a
green instrument was wrong rather than the engine. The first was my own broken
first fix, which every counter called clean. Floors and single-sided checks are
what both had in common.

## 8b. And a flaky canary in the P3 suite

The next full run failed on P3:

```
FAIL nothing was written past the last schedule slot -- last entry Y 174
```

Also not a regression. 174 is not a Y value MAXCAP has anywhere — it is a
leftover from T6X3, built moments earlier. The canary read
`schedY[schedNext * MAX_SCHED + MAX_SCHED - 1]`, assuming the schedule just
built is still sitting in NEXT; but `select_p3` builds and publishes with
interrupts live, so the frame IRQ can adopt in between, swap CURRENT/NEXT, and
leave `schedNext` naming the stale buffer.

It is a race, and both builds sit on the wrong side of it sometimes: the pre-fix
build passed it twice standalone, the fixed build passed it three times
standalone, and the fixed build failed it once under full-suite load. The
executor change shifts handler length by six cycles, which is enough to move
which side of the race a given run lands on — but it is not the cause, and
"passes on my build" would have been the wrong conclusion either way.

Corrected to read `bs_base`, the base the builder itself used — the idiom the
rest of the suite already uses for exactly this hazard. The build is the thing
under test, so the check must name its buffer the way the build did, not the
way a concurrent interrupt has since renamed it.

## 8c. Full regression, after both test corrections

```
tests/test_p0.py   ALL PASS
tests/test_p1.py   ALL PASS
tests/test_p2.py   ALL PASS
tests/test_p3.py   ALL PASS
tests/test_p4.py   ALL PASS
453 checks ok, 0 failures
```

Neither test correction weakens anything: the P2 check became strictly stronger
(every frame ran every mid-screen batch, rather than a bare floor), and the P3
canary became deterministic rather than dependent on whether an interrupt fired
between two monitor reads.

## 9. What was not done

- No feature work. P4.5 batch-density architecture and the rotating ring remain
  untouched and unstarted.
- Nothing committed or pushed.
- Manual acceptance is **not** claimed. That is yours to give.

## 10. Please retest manually

Run the engine windowed, press SPACE to **FIXTURE 16**, watch it for 30 seconds,
then compare against **FIXTURE 17**. Before the fix, FIX 16 lost the top
two-thirds of its sprites for a single frame roughly every two seconds.

## Hygiene

- Work confined to `/Users/brianmorrice/dev/C64 ASM/6502-engine`. `c64Shooter`
  untouched.
- Every automated VICE ran `-console` on an owned port, reaped on success,
  failure and timeout. No broad `pkill`, no `open -a`, no focus theft.
- Transient captures and probes in the session scratchpad, not in the repo.
- `du -sh build/` → 68K   `du -sh .` → 1.8M
