#!/usr/bin/env python3
"""P1 scrolling-renderer tests.

What this proves
----------------
* the scroller reaches every fine-scroll phase, steps coarse exactly once per
  eight frames, and flips the screen page on every coarse step;
* both screen matrices are really displayed, repeatedly, in both directions;
* $d018 always matches the software page owner for the frame;
* the sprite-pointer-table destination always belongs to the page $d018 is
  actually displaying, and is decided once per frame, never per batch;
* the DISPLAYED page's pointer bytes match the CURRENT schedule;
* a page flip is a frame-boundary event and can never land inside a batch;
* the displayed page's rows carry the world rows they should -- no stale,
  duplicated, skipped or wrong-page rows;
* the executor still consumes only published immutable state: freeze the main
  thread dead and frames keep rendering correctly;
* timing still fits, measured under the scrolling load, with the frame batch
  and mid-screen batches held to their OWN deadlines.

What this does NOT prove
------------------------
Visible correctness. See docs/manual-acceptance.md. Manual normal-speed
observation remains authoritative.

VICE process ownership: every launch is owned by PID, reaped in try/finally,
and other x64sc processes are reported but never touched.
"""
import re, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from test_p0 import (PRG, SYM, symbols, Vice, rd, set_bp, stable_read, model,
                     collect_handler_trace, free_run, read16, set_watch,
                     FIXTURES, MAX_SCHED, MAX_BATCH, FRAME_IRQ_LINE, REUSE_LEAD,
                     MUX_FIRST_SLOT, MUX_SLOTS, PAL_LINES, MIN_SPRITE_Y,
                     FRAME_BATCH_DEADLINE, FRAME_BATCH_BUDGET, LAUNCHED_PIDS)

SCRATCH = Path("/tmp/6502-engine-p1")

# --- the P1 memory map, restated independently of the assembler -------------
SCREEN_A, SCREEN_B = 0x0400, 0x2800
PTR_A,    PTR_B    = SCREEN_A + 0x3f8, SCREEN_B + 0x3f8
D018_A,   D018_B   = 0x14, 0xa4
D011_BASE          = 0x10
SCREEN_ROWS        = 25
# THE THIRD PLACE THE HUD ROW SET IS STATED, and the reason this keeps breaking.
#   1. hudRowList in src/main.asm      -- which rows the HUD draws
#   2. renderRow in src/scroll.asm     -- which rows regeneration must NOT fill
#   3. here                            -- which rows this test excludes
# Nothing makes the three agree. P5 added row 20 to (1) and not to (2) or (3),
# and this test failed on exactly the two things it exists to check. Adding a
# HUD row means editing all three.
HUD_ROWS           = (1, 2, 20, 21, 22, 23)  # P2 added 22, P3 added 21, P5 added 20.
                                     # HUD rows are excluded from the world-row
                                     # check because they are not playfield.
SPRITE_BLOCK, SPRITE_BLOCK_END = 0x2000, 0x2400
STRESS_SECONDS     = 25
TRACE_SECONDS      = 2

# screen codes produced by main.asm's hexDigit table
HEXDIGIT = [0x30,0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x38,0x39,1,2,3,4,5,6]

fails = []
def check(label, ok, extra=""):
    if not ok:
        fails.append(label)
    print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' -- ' + extra) if extra else ''}")

def w16(mon, sym, name):
    v = rd(mon, sym[name], 2)
    return v[0] | (v[1] << 8)

def w24(mon, sym, name):
    v = rd(mon, sym[name], 3)
    return v[0] | (v[1] << 8) | (v[2] << 16)

def fine16(mon, sym):
    """finePhase is eight 16-bit counters, lo/hi."""
    raw = rd(mon, sym["finePhase"], 16)
    return [raw[2 * i] | (raw[2 * i + 1] << 8) for i in range(8)]

def select_fixture(mon, sym, fx, tries=4):
    """Poke the fixture and run rebuild in isolation, leaving the CPU at
    mainLoop. Never hijacks the PC from inside the IRQ handler: doing that
    leaves the I flag set and interrupts never resume.

    VERIFIED against the independent model, and retried. An unverified
    selection silently measures the previous fixture."""
    want = len(model(FIXTURES[fx])[4])
    for _ in range(tries):
        b = set_bp(mon, sym["mainLoop"]); mon.cmd("x"); mon.cmd(f"delete {b}")
        mon.cmd(f"> {sym['fixtureIndex']:04x} {fx:02x}")
        mon.cmd("> 01ff c0"); mon.cmd("> 01fe fd")
        mon.cmd(f"r sp=fd, pc={sym['rebuild']:04x}")
        bb = set_bp(mon, 0xc0fe); mon.cmd("x"); mon.cmd(f"delete {bb}")
        mon.cmd(f"r pc={sym['mainLoop']:04x}")
        if rd(mon, sym["statBatches"])[0] == want and \
           rd(mon, sym["fixtureIndex"])[0] == fx:
            # Clear EVERY checkpoint before handing back. If one of the
            # `delete` replies above was dropped, a breakpoint stays armed on
            # mainLoop, every subsequent `x` halts on it immediately, and the
            # machine can never free-run -- which presents as a stress run that
            # reports zero frames rather than as an obvious monitor fault.
            mon.cmd("delete")
            return True
        time.sleep(0.4)
    mon.cmd("delete")
    return False

def read_page(mon, base):
    """One screen matrix, 1000 bytes."""
    return rd(mon, base, 1000)


def main():
    SCRATCH.mkdir(exist_ok=True)
    print("=== 0. build artefacts ===")
    check("build/engine.prg exists", PRG.is_file())
    check("build/main.vs exists", SYM.is_file())
    if fails:
        return 1
    sym = symbols(SYM)

    print("\n=== 1. memory map invariants ===")
    check("pointer tables sit in the last 8 bytes of their matrix",
          PTR_A == SCREEN_A + 0x3f8 and PTR_B == SCREEN_B + 0x3f8)
    check("the two pointer tables share a low byte, so ONE patched byte selects one",
          (PTR_A & 0xff) == (PTR_B & 0xff), f"${PTR_A & 0xff:02x}")
    check("$d018 page A selects screen A", ((D018_A >> 4) & 0x0f) * 1024 == SCREEN_A)
    check("$d018 page B selects screen B", ((D018_B >> 4) & 0x0f) * 1024 == SCREEN_B)
    check("both pages use the same character base",
          (D018_A & 0x0e) == (D018_B & 0x0e), f"CB bits ${D018_A & 0x0e:02x}")
    check("screen page B does not overlap the sprite bitmaps",
          SCREEN_B >= SPRITE_BLOCK_END or SCREEN_B + 0x400 <= SPRITE_BLOCK,
          f"B ${SCREEN_B:04x}-${SCREEN_B+0x3ff:04x} vs sprites "
          f"${SPRITE_BLOCK:04x}-${SPRITE_BLOCK_END-1:04x}")
    check("both pages live inside VIC bank 0", SCREEN_A + 0x400 <= 0x4000
          and SCREEN_B + 0x400 <= 0x4000)
    inside = {n: a for n, a in sym.items()
              if SCREEN_A <= a < SCREEN_A + 0x400 or SCREEN_B <= a < SCREEN_B + 0x400}
    check("no code or data symbol lands inside either screen matrix",
          not inside, f"{inside}")

    print("\n=== 1b. single-writer invariants (source level) ===")
    src = {p.name: p.read_text() for p in (ROOT / "src").glob("*.asm")}
    def count_store(reg):
        return {n: len(re.findall(r"^\s*sta\s+\$%s\b" % reg, t, re.M | re.I))
                for n, t in src.items()}
    d018 = count_store("d018")
    check("exactly one instruction writes $d018, and it is in the renderer",
          sum(d018.values()) == 1 and d018.get("renderer.asm") == 1, f"{d018}")
    ptr_writes = {n: len(re.findall(r"^\s*sta\s+PTR_[AB],x", t, re.M)) for n, t in src.items()}
    check("exactly one instruction writes a sprite pointer table",
          sum(ptr_writes.values()) == 1 and ptr_writes.get("renderer.asm") == 1,
          f"{ptr_writes}")
    patch = len(re.findall(r"sta\s+exPtrStore\s*\+\s*2", src.get("renderer.asm", "")))
    check("the pointer destination is patched from exactly one place",
          patch == 1, f"{patch} writers of exPtrStore+2")

    # =======================================================================
    print(f"\n=== 2. deterministic stress run ({STRESS_SECONDS}s of warp, fixture 2) ===")
    v = Vice(6620, PRG, warp=True)
    try:
        m = v.mon
        m.cmd("delete")
        check("fixture 2 selected and built", select_fixture(m, sym, 2))
        # Every counter is cumulative from boot, and the machine has already
        # been running while the fixture was selected. Baseline them all and
        # compare DELTAS, or the run silently measures the wrong window.
        COUNTERS = ("frameCounter", "coarseCount", "flipCount", "pageAFrames",
                    "pageBFrames", "transAB", "transBA")
        base = {c: w16(m, sym, c) for c in COUNTERS}
        base["batchCounter"] = w24(m, sym, "batchCounter")
        fine0 = fine16(m, sym)
        ran = free_run(m, sym["frameCounter"], STRESS_SECONDS)
        check("the machine actually free-ran for the whole window", ran)
        now = {c: w16(m, sym, c) for c in COUNTERS}
        now["batchCounter"] = w24(m, sym, "batchCounter")
        d = {c: now[c] - base[c] for c in base}
        frames  = d["frameCounter"]
        coarse  = d["coarseCount"]
        flips   = d["flipCount"]
        pageA   = d["pageAFrames"]
        pageB   = d["pageBFrames"]
        ab      = d["transAB"]
        ba      = d["transBA"]
        batches = d["batchCounter"]
        fine    = [a - b for a, b in zip(fine16(m, sym), fine0)]
        world   = rd(m, sym["worldRowLo"], 2)
        worldRow = world[0] | (world[1] << 8)
        pageMis = rd(m, sym["statPageMismatch"])[0]
        ptrMis  = rd(m, sym["statPtrMismatch"])[0]
        late    = rd(m, sym["statLate"])[0]
        maxLate = rd(m, sym["maxLateRun"])[0]
        sLate   = rd(m, sym["scrollLate"])[0]
        pubSkip = rd(m, sym["publishSkip"])[0]
        flipLine = rd(m, sym["lastFlipLine"])[0]
        reuse   = rd(m, sym["statReuse"])[0]

        print(f"        physical PAL frames      {frames}")
        print(f"        renderer batches         {batches}")
        print(f"        coarse steps             {coarse}")
        print(f"        page flips               {flips}   (A->B {ab}, B->A {ba})")
        print(f"        frames displayed page A  {pageA}")
        print(f"        frames displayed page B  {pageB}")
        print(f"        fine-phase counts 0..7   {fine}")
        print(f"        world row reached        {worldRow}")
        print(f"        reuse events per build   {reuse}")
        print(f"        page mismatches          {pageMis}")
        print(f"        pointer mismatches       {ptrMis}")
        print(f"        deadline misses (late)   {late}   longest run {maxLate}")
        print(f"        back page late at flip   {sLate}")
        print(f"        publication skipped      {pubSkip}")

        check("the stress run really ran", frames > 2000, f"{frames} frames")
        check("batch count matches nine batches on every frame",
              abs(batches - 9 * frames) <= 18, f"{batches} batches, {frames} frames")
        check("every fine-scroll phase was exercised many times",
              all(c > 100 for c in fine), f"{fine}")
        check("fine phases are evenly visited (deterministic 1px/frame)",
              max(fine) - min(fine) <= 2, f"spread {max(fine) - min(fine)}")
        check("one coarse step per eight frames, none missed or duplicated",
              abs(frames - 8 * coarse) <= 16, f"{frames} frames vs {coarse} coarse steps")
        check("world row advanced exactly once per coarse step",
              worldRow == now["coarseCount"],
              f"worldRow {worldRow} vs coarse steps {now['coarseCount']}")
        # coarseCount is incremented by the MAIN THREAD in scrollTick; flipCount
        # by the frame IRQ one frame later, when the record is adopted. Sampling
        # both across a window can therefore straddle one such pair. The
        # invariant is exact; the delta comparison is not, so it gets +/-1.
        check("every coarse step flipped the page", abs(flips - coarse) <= 1,
              f"{flips} flips vs {coarse} coarse steps")
        check("both screen matrices were displayed", pageA > 0 and pageB > 0,
              f"A {pageA}, B {pageB}")
        check("page frames account for every displayed frame",
              pageA + pageB == frames, f"A+B {pageA+pageB} vs frames {frames}")
        check("A->B and B->A both happen repeatedly",
              ab > 100 and ba > 100 and abs(ab - ba) <= 1, f"A->B {ab}, B->A {ba}")
        check("flips split evenly between the two directions",
              ab + ba == flips, f"{ab} + {ba} vs {flips} flips")
        check("flips and coarse steps track exactly over the whole run",
              now["flipCount"] == now["coarseCount"] or
              abs(now["flipCount"] - now["coarseCount"]) <= 1,
              f"cumulative flips {now['flipCount']} vs coarse {now['coarseCount']}")
        check("ZERO $d018 / software-page mismatches", pageMis == 0, f"{pageMis}")
        check("ZERO pointer-destination mismatches", ptrMis == 0, f"{ptrMis}")
        check("no batch ever missed its deadline", late == 0,
              f"{late} late, longest consecutive run {maxLate}")
        check("the back page was always finished before it was displayed",
              sLate == 0, f"{sLate}")
        check("no frame record was published over an unadopted one",
              pubSkip == 0, f"{pubSkip}")
        fMin = rd(m, sym["flipLineMin"])[0]
        fMax = rd(m, sym["flipLineMax"])[0]
        print(f"        flip raster min/max      {fMin} / {fMax}")
        check("page flips only ever happen at the frame IRQ line",
              flipLine == FRAME_IRQ_LINE, f"last flip at raster {flipLine}")
        check("EVERY flip of the whole run happened at the frame IRQ line",
              fMin == fMax == FRAME_IRQ_LINE,
              f"min {fMin}, max {fMax} over {now['flipCount']} flips")

        # ---- 3. displayed-page row coherence ------------------------------
        print("\n=== 3. displayed page carries the right world rows ===")
        bp = set_bp(m, sym["frameDiagnostics"]); m.cmd("x"); m.cmd(f"delete {bp}")
        cur = rd(m, sym["curPage"])[0]
        disp = rd(m, sym["dispPage"])[0]
        w = rd(m, sym["worldRowLo"], 2)
        wrow = w[0] | (w[1] << 8)
        d018 = rd(m, 0xd018)[0]
        base = SCREEN_A if cur == 0 else SCREEN_B
        check("software page and $d018 agree at the frame boundary",
              ((d018 ^ (D018_A if cur == 0 else D018_B)) & 0xfe) == 0,
              f"curPage {cur}, $d018 ${d018:02x}")
        check("the main thread's page matches the page just adopted",
              disp == cur, f"dispPage {disp}, curPage {cur}")
        page = read_page(m, base)
        bad = []
        for r in range(SCREEN_ROWS):
            if r in HUD_ROWS:
                continue
            wl = (wrow + r) & 0xff
            want = (HEXDIGIT[wl >> 4], HEXDIGIT[wl & 0x0f], 0x20, 1 + cur)
            got = tuple(page[r * 40: r * 40 + 4])
            if got != want:
                bad.append((r, wl, got, want))
        check("every displayed row prints its own world row number",
              not bad, f"{bad[:4]}")
        letters = {page[r * 40 + 3] for r in range(SCREEN_ROWS) if r not in HUD_ROWS}
        check("every displayed row was built into the SAME page",
              letters == {1 + cur}, f"page letters seen {sorted(letters)}")

        # ---- 4. pointer contents on the displayed page --------------------
        print("\n=== 4. displayed-page sprite pointers match CURRENT schedule ===")
        # Stop at the END of a frame's batches, and VERIFY the stop landed
        # there. The first resume after hijacking the PC can come to rest
        # somewhere else entirely, and an unvalidated stop reports the state
        # after batch 0 as if it were the state after batch 8.
        bp = set_bp(m, sym["exArmFrame"])
        cur_buf = n = nb = cb = 0
        for _ in range(8):
            m.cmd("x")
            cur_buf = rd(m, sym["schedCurrent"])[0]
            n  = rd(m, sym["schedEntries"] + cur_buf)[0]
            nb = rd(m, sym["schedBatches"] + cur_buf)[0]
            cb = rd(m, sym["curBatch"])[0]
            if cb == nb:
                break
        m.cmd(f"delete {bp}")
        check("stopped after the LAST batch of a frame, as intended",
              cb == nb, f"curBatch {cb}, schedBatches {nb}")
        slots = rd(m, sym["schedSlot"] + cur_buf * MAX_SCHED, n)
        ptrs  = rd(m, sym["schedPtr"] + cur_buf * MAX_SCHED, n)
        d018 = rd(m, 0xd018)[0]
        live_page = 0 if ((d018 ^ D018_A) & 0xfe) == 0 else 1
        live_ptr_base = PTR_A if live_page == 0 else PTR_B
        dest_hi = rd(m, sym["exPtrStore"] + 2)[0]
        check("pointer destination belongs to the page $d018 is displaying",
              dest_hi == (live_ptr_base >> 8),
              f"dest ${dest_hi:02x}00, displaying page {'AB'[live_page]}")
        # after the last batch each slot holds its LAST writer
        last = {}
        for i in range(n):
            last[slots[i]] = ptrs[i]
        table = rd(m, live_ptr_base, 8)
        mismatch = {s: (table[s], p) for s, p in last.items() if table[s] != p}
        check("every mux slot's pointer on the DISPLAYED page is the schedule's",
              not mismatch, f"slot: (found, expected) {mismatch}")
        check("all six mux slots were written", set(last) ==
              set(range(MUX_FIRST_SLOT, MUX_FIRST_SLOT + MUX_SLOTS)), f"{sorted(last)}")

        # ---- 5. page-flip atomicity ---------------------------------------
        print("\n=== 5. page flip atomicity ===")
        # The evidence that a flip cannot land inside a batch is in-engine and
        # covers EVERY flip, not a sample:
        #
        #   * flipLineMin == flipLineMax == 250 over the whole stress run
        #     (checked in section 2), sampled at frame-IRQ ENTRY;
        #   * exactly one `sta $d018` exists in the whole program and it is
        #     inside exFrame (checked at source level in section 1b);
        #   * exFrame runs only when curBatch == 0, before any batch programs a
        #     sprite, so a flip cannot fall between an entry's Y write and its
        #     pointer/colour writes.
        #
        # Stepping a watchpoint was tried and abandoned: the remote monitor
        # returns from `x` on a prompt echo rather than on the actual stop, so
        # the "samples" it collects are whatever raster the next command happens
        # to halt on. That instrument cannot answer this question; the counters
        # can.
        rasters = [rd(m, sym["flipLineMin"])[0], rd(m, sym["flipLineMax"])[0]]
        print(f"        flip raster min/max across every flip: {rasters}")
        check("every $d018 write happens at the frame IRQ line",
              all(r == FRAME_IRQ_LINE for r in rasters), f"{rasters}")
        check("no $d018 write lands inside the display window",
              all(not (MIN_SPRITE_Y <= r <= 246) for r in rasters),
              f"rasters {sorted(set(rasters))}")
    finally:
        v.close()

    # =======================================================================
    print("\n=== 6. renderer immutability: freeze the main thread dead ===")
    v = Vice(6621, PRG, warp=True)
    try:
        m = v.mon
        m.cmd("delete")
        check("fixture 2 selected and built (immutability run)",
              select_fixture(m, sym, 2))
        # park the main thread on a jmp-to-self in free RAM. Done at mainLoop,
        # never from inside the IRQ: hijacking the PC while stopped in the
        # handler leaves the I flag set and interrupts never resume.
        b = set_bp(m, sym["mainLoop"]); m.cmd("x"); m.cmd(f"delete {b}")
        m.cmd("> 02a7 4c a7 02")          # jmp $02a7
        m.cmd("r pc=02a7")
        before_frames = w16(m, sym, "frameCounter")
        before_page = rd(m, sym["curPage"])[0]
        before_mis = (rd(m, sym["statPageMismatch"])[0], rd(m, sym["statPtrMismatch"])[0])
        free_run(m, sym["frameCounter"], 6)
        after_frames = w16(m, sym, "frameCounter")
        after_batches = w16(m, sym, "batchCounter")
        after_mis = (rd(m, sym["statPageMismatch"])[0], rd(m, sym["statPtrMismatch"])[0])
        pc = None
        for _ in range(6):
            pc = re.search(r"\.;([0-9a-f]{4})", m.cmd("r"))
            if pc:
                break
            time.sleep(0.3)
        print(f"        frames rendered with the main thread parked: "
              f"{after_frames - before_frames}")
        check("the main thread really is parked", pc is not None and pc.group(1) == "02a7",
              f"pc {pc.group(1) if pc else '?'}")
        check("frames keep rendering after the main thread stops dead",
              after_frames - before_frames > 200, f"{after_frames - before_frames}")
        check("no coherence fault appears once publication stops",
              after_mis == before_mis == (0, 0), f"{before_mis} -> {after_mis}")
        # the executor must still be programming sprites from CURRENT alone
        # Stop at the END of a frame's batches, and VERIFY the stop landed
        # there. The first resume after hijacking the PC can come to rest
        # somewhere else entirely, and an unvalidated stop reports the state
        # after batch 0 as if it were the state after batch 8.
        bp = set_bp(m, sym["exArmFrame"])
        cur_buf = n = nb = cb = 0
        for _ in range(8):
            m.cmd("x")
            cur_buf = rd(m, sym["schedCurrent"])[0]
            n  = rd(m, sym["schedEntries"] + cur_buf)[0]
            nb = rd(m, sym["schedBatches"] + cur_buf)[0]
            cb = rd(m, sym["curBatch"])[0]
            if cb == nb:
                break
        m.cmd(f"delete {bp}")
        check("stopped after the LAST batch of a frame, as intended",
              cb == nb, f"curBatch {cb}, schedBatches {nb}")
        ys = rd(m, sym["schedY"] + cur_buf * MAX_SCHED, n)
        s2 = rd(m, sym["schedSlot2"] + cur_buf * MAX_SCHED, n)
        regs = rd(m, 0xd000, 16)
        last_y = {}
        for i in range(n):
            last_y[s2[i]] = ys[i]
        wrong = {s: (regs[s + 1], y) for s, y in last_y.items() if regs[s + 1] != y}
        check("sprite Y registers still match CURRENT with no main thread",
              not wrong, f"slot*2: (found, expected) {wrong}")
        check("the frozen frame still used all six mux slots", len(last_y) == MUX_SLOTS,
              f"{len(last_y)}")
    finally:
        v.close()

    # =======================================================================
    print("\n=== 7. executor timing under the scrolling load ===")
    v = Vice(6622, PRG, warp=True)
    log = SCRATCH / "p1trace.log"
    try:
        m = v.mon
        m.cmd("delete")
        check("fixture 2 selected and built (timing run)", select_fixture(m, sym, 2))
        armed = [b["line"] for b in model(FIXTURES[2])[4]]
        fine_before = fine16(m, sym)
        pairs = collect_handler_trace(m, log, sym)
        fine_after = fine16(m, sym)

        byline = {}
        for l, c in pairs:
            byline.setdefault(l, []).append(c)
        FRAME_ENTRY = (FRAME_IRQ_LINE, FRAME_IRQ_LINE + 1)
        frame_costs = [c for l, cs in byline.items() if l in FRAME_ENTRY for c in cs]
        mid = [c for l, cs in byline.items() if l not in FRAME_ENTRY for c in cs]
        phases_seen = sum(1 for a, b in zip(fine_before, fine_after) if b > a)

        print(f"        handler pairs sampled    {len(pairs)}")
        print(f"        fine phases active       {phases_seen} of 8 during the window")
        print(f"        frame batch  (line {FRAME_IRQ_LINE})  "
              f"min {min(frame_costs)}  max {max(frame_costs)} cycles "
              f"({max(frame_costs)/63:.2f} lines)")
        print(f"        mid-screen batches       min {min(mid)}  max {max(mid)} cycles "
              f"({max(mid)/63:.2f} lines) over {len(mid)} samples")
        for l in sorted(byline):
            cs = byline[l]
            print(f"          line {l:3d}: n={len(cs):4d}  min={min(cs):4d}  max={max(cs):4d}")

        check("enough timing samples under scroll", len(pairs) >= 1000, f"{len(pairs)}")
        check("all eight fine phases were active during the timing window",
              phases_seen == 8, f"{phases_seen}")
        check("MID-SCREEN batch cost still fits the REUSE_LEAD budget",
              max(mid) <= REUSE_LEAD * 63,
              f"{max(mid)} cy vs {REUSE_LEAD*63} cy ({REUSE_LEAD} lines)")
        check("REUSE_LEAD is still safe under scrolling and needs no change",
              max(mid) <= REUSE_LEAD * 63,
              f"worst mid-screen batch uses {100*max(mid)/(REUSE_LEAD*63):.0f}% of the budget")
        check("FRAME batch fits its own deadline",
              max(frame_costs) <= FRAME_BATCH_BUDGET,
              f"{max(frame_costs)} cy vs budget {FRAME_BATCH_BUDGET} cy; "
              f"real deadline {FRAME_BATCH_DEADLINE} cy")
        if log.exists():
            log.unlink()
    finally:
        v.close()

    print("\n=== 8. cleanup ===")
    leftovers = list(SCRATCH.glob("*"))
    check("no transient test artefacts left in scratch", not leftovers,
          f"{[p.name for p in leftovers]}")
    r = subprocess.run(["pgrep", "-fl", "x64sc"], capture_output=True, text=True)
    running = {}
    for line in r.stdout.splitlines():
        pid, _, cmd = line.partition(" ")
        # Match the EXECUTABLE, not any command line that merely contains
        # "x64sc" -- a grep over this very output otherwise reports itself as a
        # stray emulator.
        if not cmd.split(" ")[0].endswith("x64sc"):
            continue
        try:
            running[int(pid)] = cmd
        except ValueError:
            pass
    mine = {p: c for p, c in running.items() if p in LAUNCHED_PIDS}
    check("no test-owned VICE process remains", not mine, f"{mine}")
    others = {p: c for p, c in running.items() if p not in LAUNCHED_PIDS}
    print(f"        launched and reaped: {LAUNCHED_PIDS}")
    print(f"        other x64sc processes (NOT ours, left alone): {others or 'none'}")

    print(f"\n=== {'ALL PASS' if not fails else str(len(fails)) + ' FAILURES: ' + ', '.join(fails[:6])} ===")
    return 1 if fails else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        try:
            SCRATCH.rmdir()
        except OSError:
            pass
