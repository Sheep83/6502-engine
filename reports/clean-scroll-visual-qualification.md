# Clean scroll visual qualification

**Result: the visible aperture now contains scrolling terrain only. Scroll
smoothness is NOT declared here — that is the manual test in §7.**

One build switch, three guarded blocks, no engine change.

---

## 1. The visible diagnostic rows that existed

Verified against current source, not taken from the previous report. The six
rows named by `hudRowList` in `src/main.asm` all sat inside the aperture:

| matrix row | constant | content |
|---|---|---|
| 1 | `HUD_ROW_STATS` | `FIX nn ACC nn REU nn MRG nn UNS nn` |
| 2 | `HUD_ROW_SCROLL` | scroll/page state, fine-scroll digit, page letter |
| 20 | `HUD_ROW_P5` | orbit and X=255 census |
| 21 | `HUD_ROW_P3` | motion, capacity and sorter faults |
| 22 | `HUD_ROW_P2` | geometry identification |
| 23 | `HUD_ROW_FIX` | `FIXTURE nn SPC=NXT M=3 S=4 R=5`, reverse video, full width |

A seventh piece of contamination was found that the previous report did not
name: `initColour` painted those same six rows **white** (`$01`) across an
otherwise uniform light-grey field. Removing only the characters would have left
six stationary white bands with grey terrain scrolling through them — the same
visual contamination in a different form. It is removed too.

## 2. What drew them

Two call sites, and only two:

- `jsr hudTick` in `mainLoop` (`src/main.asm`) — one row per frame, round robin,
  written into the page that is on screen **now**;
- `jmp drawHudRow` in `renderRow` (`src/scroll.asm`) — the back-page
  regeneration reserving those six rows so a flipped page is complete.

Plus the colour band in `initColour`. Nothing else writes the screen matrix;
`grep` for `scrPtr`, `SCREEN_A` and `SCREEN_B` confirms `scroll.asm` is the only
other writer.

## 3. How they were removed

The "best/simple option" from the brief: the diagnostic rows are not drawn, and
those rows render ordinary world content instead. Nothing moved to the border,
no raster phase was added, no sprite work was touched.

One assemble-time constant, `HUD_VISIBLE`, in `src/main.asm`:

```asm
.const HUD_VISIBLE    = false
```

guards exactly three blocks:

1. `mainLoop` — `jsr hudTick` is not assembled;
2. `initColour` — the six white rows are not painted;
3. `renderRow` (`src/scroll.asm`) — the six-way HUD reservation chain is
   replaced by a straight `jmp renderBackgroundRow`, so rows 1, 2 and 20-23 are
   regenerated as world rows like every other row in the aperture.

Why a switch rather than deletion: the HUD is the only readout for `statAccepted`,
`statOverflow`, the sorter faults and the P5 census, and it will be wanted again.
All the drawing code is still assembled and still correct; setting the constant
true restores it exactly. The three sites are the same three the source already
warns about — `main.asm` comments call the HUD row set "stated in three places"
— so they were easy to find and are now all keyed off one symbol.

**Fixture selection is untouched.** SPACE, M, S and R still work, `fixtureIndex`
is still the live selection, and nothing about `rebuild`/`loadFixture` changed.
The only loss is that the selection is no longer *printed*; it is readable at
`$0c52` if the harness needs it. No logging feature was built.

## 4. Guard rows retained

Unchanged and re-measured. `renderGuardRow` still fills matrix rows 0 and 24
with spaces, and the guard test runs **before** the HUD dispatch in `renderRow`,
so it is outside the switch entirely:

```
[boot]      row 0 blank    row 24 blank
[boot+3s]   row 0 blank    row 24 blank
[MAXCAP]    row 0 blank    row 24 blank
[RING-SLOW] row 0 blank    row 24 blank
```

Every sample: all 40 bytes `$20`. The coarse seam mask is intact.

## 5. Nothing architectural changed

Not touched, and the diff shows it: fine scroll, coarse scroll, page flip,
hidden-page regeneration, the NEXT/CURRENT schedule model, `exBorder`, the
raster-250 frame transaction, renderer timing, sprite admission, HUD ownership.

The complete production diff for this task is three `.if (HUD_VISIBLE)` wrappers
and one constant. No instruction inside any of those blocks was modified.

The one real behavioural consequence: `hudTick` no longer costs main-thread time,
and regeneration no longer stamps six HUD rows into the back page. That can only
*reduce* per-frame preparation, which is the exact cost the source documents as
having pushed P3's heaviest fixture to ~88% of a frame. Publication skips were
deliberately not measured or optimised here.

## 6. Targeted test results

`make build` — clean, no warnings, same memory map.

Targeted check, one owned `x64sc`, warp, `-console`:

```
=== boot / fixture 0 ===
  ok  row 0 / row 24 blank guard rows
  ok  every aperture row 1..23 carries world content
  ok  every aperture row came from the SAME page          letters [2]
  ok  ex-HUD rows 1,2,20-23 hold terrain only, no HUD content
  ok  world row numbers count by one down the aperture
  ok  coarse scroll advanced                              2219 -> 2531
  ok  page/pointer coherence clean        statPageMismatch 0  statPtrMismatch 0
  ok  scroller not late, sorter no faults  scrollLate 0  sortFault 0
  ok  frame transaction still enters at raster 250        250

=== MAXCAP smoke (fixture 22) ===
  ok  selected; guard rows blank; rows 1..23 terrain, one page, counting by one
  ok  coherence clean, frameEntryLine 250, accepted 24

=== RING-SLOW smoke (fixture 31) ===
  ok  selected; guard rows blank; rows 1..23 terrain, one page, counting by one
  ok  coherence clean, frameEntryLine 250, accepted 16

FAILURES: none
```

The ex-HUD row check is not a formality: it reads the six rows and rejects any
byte outside terrain's closed alphabet (hex digits, space, the page letter, the
reverse-space bar `$a0`, the `*` walker). Reverse-video HUD label text uses
codes that cannot appear in that set, so surviving diagnostic content would
fail it. All six rows now also take part in the "count by one" and "same page"
checks, which previously skipped them.

One measurement needed a second look. RING-SLOW first read `statAccepted = 0`
where the previous report recorded 16. It is a sampling artefact, confirmed
rather than assumed: `statAccepted` is cleared at the top of `buildSchedule` and
refilled as the pass runs, and a moving fixture republishes every frame, so a
monitor stop at a random instant can land inside that window.

```
statAccepted at random stops     [0, 16, 0, 0, 16, 16, 0, 0, 0, 0, 0, 0]
statAccepted stopped at mainLoop [16, 16, 16, 16, 16, 16]
```

Deterministic stops give 16 every time. Not a regression, and the table above
reports the deterministic figure.

Not run, on purpose: `test_p1` (~11 min), `make test-fast` (~14 min), the full
suite. No production engine mechanism changed, so the brief's condition for
running them is not met. `test_p1` still **passes unchanged** if you want it —
it excludes `HUD_ROWS` from its checks, so the six rows becoming world rows can
only make it stricter, not fail it. If `HUD_VISIBLE` stays false beyond this
qualification, `HUD_ROWS` in `tests/test_p1.py` should be emptied so those six
rows are actually verified rather than skipped; that is a test change and is
deliberately left for the next task.

## 7. Manual test — this is the qualification

The currently running windowed VICE (pid 33374) is on the **old** binary. Quit
it and relaunch:

```sh
make run
```

Windowed, normal speed, no warp. SPACE cycles fixtures; M / S / R jump to the
first P3 / P4 / P5 fixture. There is no on-screen fixture label any more — the
sprites themselves tell you which one you are on.

The screen should now be:

```
OPEN TOP BORDER
blank guard row
terrain  (rows 1..23, uniform light grey, scrolling)
blank guard row
OPEN BOTTOM BORDER
```

The questions that matter:

1. Is the visible playfield free of stationary-looking diagnostic bars, white
   bands, text and horizontal reference lines?
2. Is the terrain scroll visually smooth?
3. Are there visible one-frame hitches?
4. Are page flips and coarse steps now visually unobtrusive?
5. Do MAXCAP (24 numerals) and the P5 rings (16 sprites) still look correct?

Question 3 is the one this task exists to make answerable. Roughly 12-15% of
frames still defer the frame record, which is one frame of scroll hitch and
never sprite corruption. **Whether that is objectionable is your call, not the
harness's**, and it is deliberately not pre-judged here.

If the scroll still hitches:

```
clean visual field achieved;
manual judgement now required;
if user reports hitching, next task should investigate frame-record
publication / regeneration budget.
```

Do not fix it in this task.

## 8. VICE and disk hygiene

`pgrep -fl x64sc` before: **pid 33374, your own manual windowed session**. It was
accounted for, left running, and never touched. Every automated launch was
`-console`, retained its exact PID, and was reaped in `finally`:

```
  [vice] launched pid 34563 on port 6512 ... reaped pid 34563 (rc=-15)
  [vice] launched pid 34654 on port 6513 ... reaped pid 34654 (rc=-15)
```

After: only pid 33374 remains. No broad `pkill`, no `open -a`, no window mapped,
no focus taken. Transient scripts and captures lived in the session scratchpad
and are deleted; a stale empty `/tmp/6502-engine-p4` from an earlier session was
removed.

```
du -sh build/     68K
du -sh .         2.5M
```

`build/` holds `engine.prg`, `main.sym`, `main.vs` and nothing else. Not
committed.
