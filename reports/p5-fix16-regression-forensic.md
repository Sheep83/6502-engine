# P5 → FIX 16 regression forensic

**Verdict: AMBER.**

I could not reproduce the corruption you photographed, and I am not going to
claim a root cause I cannot demonstrate. What this report gives you instead is:
everything that has been **ruled out with evidence**, the one genuine test gap
that P5 exposed (now closed and proved), and the precise information I need from
you to finish the job.

**The manual-GREEN claim for FIX 16 is withdrawn.** Your screenshot is
authoritative and it shows a fixture that is not rendering correctly.

---

## 1. Exact current reproduction — and the honest result

I could not reproduce it. Across four independent attempts on the current build,
every accepted MAXCAP sprite rendered as exactly the bitmap its schedule entry
points at:

| attempt | path | frames | emulated span | result |
|---|---|---|---|---|
| consecutive | cold boot → FIX 16 | 60 | 1.2 s | clean |
| consecutive | 1F → 20 → 21 → FIX 16 | 60 | 1.2 s | clean |
| consecutive | pre-`renderRow`-fix build | 20 | 0.4 s | clean |
| **spread** | 1F → 20 → 21 → FIX 16 | 21 | **42 s** | clean |

"Clean" means: every one of the 24 accepted sprites showed its own 64-byte
graphic, in its own colour, at the position the independent model puts it. The
only pixels that ever differ are **46 pixels of logical sprite 0**, which sits at
Y=50 and has its top rows cut by the upper border because the engine runs
RSEL=0 for scrolling. That difference is constant on every frame of every run
and was already characterised during the FIX 16 forensic.

All of this was run in `-console` non-warp VICE, which is timing-faithful.

### What I did observe, and it is not your fault

My first capture showed only **six** sprites at fixture 0's geometry
(X 30/60/90…, Y 60/90/120… — 30 rasters apart) while the HUD read `FIX 16`,
`ACC 18`, `OVF 06`. That is a **harness** defect, not an engine one: my ad-hoc
selection helper hijacked the PC to call `rebuild` without verifying the call
completed, and the documented monitor trap in `AGENTS.md` — "the monitor returns
from `x` on a prompt echo rather than on the actual stop" — let it abort the
rebuild mid-flight and jump to `mainLoop`. `logCount` had been set to 30 but
`sortReset` had not run, so `sortedCount` was still 16 from the ring fixture and
the builder accepted 16 instead of 24.

The repository's real helper, `select_p3`, guards exactly this by verifying the
result against the model and retrying. Once I used it, the symptom vanished
completely. I am recording it because for about an hour it looked like a
spectacular engine bug, and it was mine.

## 2 & 3. Clean control state and current broken state

```
KNOWN CLEAN   282b48d  "P4.6 complete"   -- post-FIX16, manually accepted
KNOWN BROKEN  working tree              -- all P5 work, uncommitted
```

Every P5 change is still uncommitted, which made the comparison exact. The clean
state was built in a throwaway worktree at `/tmp/f16clean` and is untouched.

## 4. P5-era change inventory

| file | change |
|---|---|
| `src/p5_tables.asm` | **new** — 1 KB of orbit tables at `$2400` |
| `src/p5_ring.asm` | **new** — `ringTick`/`ringPlace`/`loadRingFixture` at `$1300`, state at `$c506` |
| `src/fixtures.asm` | `FK_RING`, three records, dispatch tables, `FIXTURE_COUNT` 31→34 |
| `src/main.asm` | HUD row 20 + `drawP5Row`, `readJumpP5` (R key), `fixLineText` reflow |
| `src/motion.asm` | `ringActive` branch in `motionTick`; `clearMotion` clears it |
| `src/scroll.asm` | `renderRow` must skip HUD row 20 |
| tests, tools, docs | model, generator, suite, ladder |

## 5. Bisect result

No P5-era change reproduced the failure. I specifically tested the one engine
change I made *after* my intermediate "P5 is built and verified" message — the
`renderRow` row-20 fix — on the assumption you may have tested that earlier
binary. It renders MAXCAP cleanly too.

**First breaking change: not identified.** That is why this is AMBER.

## 6. Memory-map comparison

```
                     CLEAN (282b48d)        P5 (current)
main                 $0810-$0bd0            $0810-$0c76
p5 ring              --                     $1300-$13f6      NEW
fixtures             $1800-$18a1            $1800-$18ad
fixtures code        $18d0-$19e3            $18d0-$19ea
scroller             $1a00-$1bf6            $1a00-$1bfa
motion               $1c00-$1d0a            $1c00-$1d15
diagnostic sprites   $2000-$23ff            $2000-$23ff      unchanged
p5 ring tables       --                     $2400-$27ff      NEW
p5 ring state        --                     $c506-$c516      NEW
fixture dispatch     $ca00-$ca7b            $ca00-$ca87
```

**No overlaps.** Verified programmatically over every segment pair. The tightest
gaps are worth knowing:

```
$19ea -> $1a00   21 bytes   (fixtures code -> scroller)
$1bfa -> $1c00    5 bytes   (scroller -> motion)      <-- tightest
$23ff -> $2400    0 bytes   (sprite bitmaps -> P5 ring tables)
$c505 -> $c506    0 bytes   (motion state -> P5 ring state)
```

Five bytes of headroom between the scroller and motion is uncomfortably thin.
KickAssembler places explicit `*=` segments without complaining when they collide,
so growth there would corrupt code silently. That is a real fragility P5
introduced and it is called out in section 16.

## 7. MAXCAP accepted-24 pointer/identity table

Read from the running machine, CURRENT buffer, on the current build:

```
 acc id slot  ptr   -> address   region            acc id slot  ptr   -> address
  0   0   2  $80  -> $2000  BITMAP POOL            12  12   2  $8c  -> $2300
  1   1   3  $81  -> $2040  BITMAP POOL            13  13   3  $8d  -> $2340
  2   2   4  $82  -> $2080  BITMAP POOL            14  14   4  $8e  -> $2380
  3   3   5  $83  -> $20c0  BITMAP POOL            15  15   5  $8f  -> $23c0
  4   4   6  $84  -> $2100  BITMAP POOL            16  16   6  $80  -> $2000
  5   5   7  $85  -> $2140  BITMAP POOL            17  17   7  $81  -> $2040
  6   6   2  $86  -> $2180  BITMAP POOL            18  18   2  $82  -> $2080
  7   7   3  $87  -> $21c0  BITMAP POOL            19  19   3  $83  -> $20c0
  8   8   4  $88  -> $2200  BITMAP POOL            20  20   4  $84  -> $2100
  9   9   5  $89  -> $2240  BITMAP POOL            21  21   5  $85  -> $2140
 10  10   6  $8a  -> $2280  BITMAP POOL            22  22   6  $86  -> $2180
 11  11   7  $8b  -> $22c0  BITMAP POOL            23  23   7  $87  -> $21c0
```

Every pointer is `$80`–`$8F`; every one resolves inside `$2000`–`$23FF`; the
`AND #15` wrap for ids 16–23 is correct. `logPtr[0..29]` likewise contains only
`$80`–`$8F`.

## 8. Corrupted VIC fetch evidence

**None found.** This is the section that would carry the answer and it is empty,
which is the substance of the AMBER.

- The bitmap pool in RAM hashes `6a205f9d1aa0`, **byte-identical to the same
  pool during the FIX 16 forensic** and byte-identical to `build/engine.prg`.
- All 16 blocks are pairwise distinct.
- The VIC's own sprite Y registers step 86, 92, 98, 104, 110, 116 across
  successive batches — exactly MAXCAP's geometry.
- `$D018 = $a5` (screen `$2800`), pointer destination `$2bf8` — consistent.
- `statPageMismatch = 0`, `statPtrMismatch = 0`, `sortFault = 0`,
  `frameEntryLine = 250`.

What the striped garbage in your screenshot *looks* like is a sprite pointer of
`$90`–`$9F`, which resolves to `$2400`–`$27FF` — the new P5 ring tables. Those
are smooth coordinate ramps (`3c 3c 3c 3c 3b 3b 3a 3a 39 39 38 37 …`) and
rendered as a sprite they would produce exactly that horizontal banding. **I
could not get any pointer to take such a value**, but the coincidence is close
enough that it drove the two guards in sections 17–18.

## 9. Diagnostic / screen-RAM bounds audit

Every P5 writer, bounded and checked:

| writer | row | offsets written | page A | page B | pointer table |
|---|---|---|---|---|---|
| `drawP5Row` template | 20 | 0…39 | `$0720-$0747` | `$2B20-$2B47` | clear |
| `drawP5Row` `putHexY` | 20 | 9,11,18,20,27,29,37 (+1) | max `$0746` | max `$2B46` | clear |
| `drawFixRow` text | 23 | 0…29 | `$0778-$0795` | `$2B98-$2BB5` | clear |
| `drawFixRow` pad | 23 | 31…39 | `$0797-$079F` | `$2BB7-$2BBF` | clear |
| `drawFixRow` keyDown | 23 | 30 | `$0796` | `$2BB6` | clear |
| `renderRow` row 24 | 24 | 0…39 | `$07C0-$07E7` | `$2BC0-$2BE7` | clear |
| `initColour` row 20 | — | `$DB20-$DB47` | — | — | n/a |

The pointer tables are at `$07F8` and `$2BF8`. The closest any writer comes is
`$07E7` — **16 bytes clear**. The `FIXLINE_LEN`/`KEY_COL` assertions added
during the P4 flicker forensic still hold with the reflowed fixture line.

## 10. Pointer-table write audit

A store watchpoint on `$07f8-$07ff` and `$2bf8-$2bff` was built
(`watch.py`, preserved) to attribute every writer by PC. In the runs completed,
the only writer reached is the executor's single patched store, `exPtrStore`.
This remains the strongest tool if you can reproduce on demand — see section 21.

## 11. Fixture setup/teardown audit

Both paths were tested. The switch **ring → MAXCAP** was traced instruction-level:

```
loadFixture -> clearMotion -> sortReset -> republish -> sortTick
            -> buildSchedule -> publishSchedule
result: logCount 30, sortedCount 30, accepted 24, overflow 6, ringActive 0
```

`clearMotion` clears `ringActive` and `fixtureMoves`; `fixtureKind[22] = 0`
(`FK_STATIC`) and `fixtureLen[22] = 30`, both read back from the assembled
tables rather than counted by eye. No ring state survives the switch.

## 12. Capacity / overflow bounds

30 offered, 24 accepted, 6 overflow, `statBatchOverflow = 0`, on every run in
both navigation paths. P4's existing canary — an overflowing build never writes
outside its own buffer — still passes.

## 13. Frame-raster-250 status

`frameEntryLine = 250` on every sample, in both paths, on every build tested.
The FIX 16 root cause (a raster IRQ latched after the handler's single
acknowledge, re-entering with `curBatch` wrapped to 0) has **not** recurred.

## 14. Why the P5 ring fixtures stay clean

They use only bitmaps 0–15 with no wrap (16 sprites, 16 blocks, one-to-one), so
the `AND #15` path that MAXCAP depends on for ids 16–29 is never exercised.
They are also `FK_RING`/moving, so they rebuild and republish every frame —
a stale schedule or a lost publication self-corrects within one frame, where a
static fixture like MAXCAP publishes **once** and lives with the result.

That asymmetry is real and it is the best remaining lead: **MAXCAP is the only
fixture in the set whose entire presentation depends on a single publication
surviving.** Any one-off disturbance at selection time persists indefinitely on
MAXCAP and is invisible on every moving fixture.

## 15. Why the automated tests missed it

Two distinct gaps, one of which I have closed:

**(a) The semantic pointer check was too weak.** The FIX 16 forensic's invariant
was effectively *"the pointer resolves inside the sprite bitmap allocation"*.
That cannot tell sprite 7's graphic from sprite 9's, and it cannot notice a
bitmap overwritten at run time. Demonstrated below: a pointer of `$81` where
`$87` belongs passes the old rule and fails the new one.

**(b) Sampling span.** My P5-era visual checks sampled *consecutive* frames —
60 frames is **1.2 seconds** of emulated time. You watch for minutes. Consecutive
sampling covers almost none of the scroll positions, page flips and fine-scroll
phases the fixture visits. The sampler now spreads captures across a long run,
and that is how the 42-second sweep in section 1 was taken.

## 16. Root cause

**Not identified.** Reporting AMBER rather than guessing, as the brief directs.

What is *established*: the builder, the schedule, the pointers, the pool
contents, the memory map, the fixture switch, the capacity path and the
raster-250 invariant are all correct on the current build in my environment.

## 17. Fix

**No speculative fix applied.** Nothing was moved, clamped, reduced or hidden.
MAXCAP still offers 30, accepts 24 and overflows 6; P5 is unweakened.

Two guards were added, both targeting the *class* of risk P5 introduced rather
than a guessed instance:

**Assembly-time ownership rule** (`src/p5_tables.asm`, generated):

```asm
.if (P5_TABLE_BASE < spriteBitmapsEnd)            { .error "P5 ring tables overlap the sprite bitmap pool" }
.if (P5_TABLE_BASE + P5_TABLE_BYTES > SCREEN_B)   { .error "P5 ring tables overlap screen page B" }
```

The tables sit in the 1 K hole between the bitmap pool and screen page B. That
is legal and cheap, and it is also the most dangerous address in the map, for
the reason section 8 gives. The rule is now stated and enforced instead of
assumed.

## 18. New regression

`tests/sprite_identity.py`, wired into `tests/test_p3.py`'s MAXCAP section. The
invariant is the strong one the brief asks for:

> logical sprite ID X resolves to the **exact** 64-byte block holding X's
> diagnostic graphic, and that block still contains **exactly** the bytes the
> assembler put there.

Independence matters here: the expected bytes are read from
**`build/engine.prg`**, not from RAM and not from a Python re-implementation of
the KickAssembler font generator. Re-deriving the glyphs would only prove two
copies of the same logic agree; reading the build artefact proves memory matches
what was built. It also checks that all 16 blocks are pairwise distinct — if two
graphics were identical, neither a human nor the test could tell a mis-pointed
sprite from a correct one.

## 19. Proof the new regression fails on the old fault

```
1. healthy MAXCAP schedule
   -> clean
2. ONE pointer bumped to $90 (resolves to $2400, the P5 ring tables)
   -> MAXCAP: accepted 7 is logical id 7, which must carry pointer $87 ($21c0)
      but carries $90 ($2400)
3. ONE pointer naming another sprite's block ($81 instead of $87)
   -> MAXCAP: accepted 7 is logical id 7, which must carry pointer $87 ($21c0)
      but carries $81 ($2040)
4. a bitmap OVERWRITTEN in RAM by one byte (the P4 class)
   -> MAXCAP: bitmap 7 at $21c0 differs from the build in 1/64 bytes
      (ram 3661ce3a vs prg d9b367b6)

the OLD invariant, for comparison
   $90 -> ring tables : 'resolves inside the pool' -> caught
   $81 -> wrong sprite: 'resolves inside the pool' -> OK (MISSED)
```

Case 3 is the important one: the old rule passes it, the new rule catches it.

## 20. Regression result

No engine behaviour was changed, so a full P0–P5 sweep is not the gate here —
and the assertion guard was proved to emit nothing:

```
engine.prg without the ownership guard : 9ee3610ba5cf6306
engine.prg with    the ownership guard : 9ee3610ba5cf6306   IDENTICAL
```

What was run, targeted as the brief prescribes for forensic work:

```
tests/test_p3.py          ALL PASS   -- contains MAXCAP and the new identity check
  ok  every accepted sprite resolves to its OWN 64-byte diagnostic bitmap,
      byte for byte -- 24 accepted ids -> 16 distinct pointers, all matching
      build/engine.prg
  ok  MAXCAP accepts exactly MAX_SCHED and no more -- 24
  ok  the sprites that did not fit are COUNTED, not truncated silently -- 6
  ok  MAXCAP schedule still matches the model exactly
  ok  nothing was written past the last schedule slot

P5 controls 1F / 20 / 21   clean in every pixel diff run (sections 1, 14)
frame-raster-250            250 on every sample, every path, every build
memory-map overlap          none, verified programmatically
```

The full P0–P5 ladder should be re-run once a root cause is actually found and
fixed; running it now would only re-prove a binary that is byte-identical to the
one already qualified.

## 21. What I need from you to finish this

I cannot close a fault I cannot reproduce, and guessing would risk "moving data
around until the corruption disappears", which the brief rightly forbids. Four
things would let me finish:

1. **Does it still happen after `make clean && make`?** If a stale
   `build/engine.prg` is involved, this ends it immediately.
2. **Is it continuous or intermittent** — garbage on every frame, or flickering?
3. **Exactly how do you reach FIX 16?** SPACE from 0, SPACE round from `21`, or
   `M` then SPACE? Section 14 explains why the *route* may matter: MAXCAP is the
   only fixture whose whole presentation rides on a single publication.
4. **Does it survive leaving FIX 16 and coming back?** And does cold-booting
   straight to it differ from arriving after the ring fixtures?

If it reproduces on demand for you, the watchpoint tool in section 10 will name
the culprit PC in one run.

## 22. VICE and process hygiene

`pgrep -fl x64sc` before the work and after: **none**. Every launch retained its
exact PID and was reaped; one long-running sampler was stopped deliberately and
its owned VICE killed by exact PID, then verified gone. No broad `pkill`, no
`open -a`, `-console` throughout, no focus taken. `/tmp/6502-engine-p4` holds
**0** trace logs. The `/tmp/f16clean` worktree is retained deliberately as the
clean control and can be removed with `git worktree remove /tmp/f16clean`.

## 23. Disk usage

```
du -sh build/    68K
du -sh .         2.1M
```

Transient captures live in the session scratchpad, not in the repository.
