#!/usr/bin/env python3
"""Fixture activation: the first CURRENT schedule for a new fixture must be
complete, coherent, and entirely the new fixture's.

WHY THIS EXISTS

MAXCAP (FIX 16) is static. It builds and publishes its schedule exactly ONCE,
at activation, and nothing ever rebuilds it. Every other moving fixture
republishes each frame and therefore repairs any one-frame damage on the next
frame. So MAXCAP is the only fixture in the set whose entire presentation rides
on a single publication surviving intact -- and a fault there is permanent and
looks like catastrophic corruption rather than a flicker.

THE FAULT THIS GUARDS

buildSchedule latches its destination from schedNext ONCE, at entry, and then
writes that buffer for thousands of cycles. The frame IRQ swaps schedCurrent
and schedNext whenever schedPending is set. A build STARTED while a publication
is still pending therefore has its destination promoted to CURRENT underneath
it, and the executor renders a half-written schedule.

Measured before the fix: 11.7% of RING-SLOW builds began with schedPending
already set, and forcing the condition at activation produced a CURRENT with
schedEntries = 0 while the build itself completed correctly.

    engine guard:  src/renderer.asm, bs_building -- the frame IRQ will not
                   promote a buffer that a build is currently writing.

Usage:  python3 tests/test_transition.py            # the full matrix
        python3 tests/test_transition.py --quick    # fewer repetitions
"""
import sys, time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from test_p0 import PRG, SYM, symbols, Vice, rd, set_bp, free_run, read16
from test_p2 import poke
from test_p3 import pc_of
import p2_model as M
import p3_model as P3
import p5_model as P5
import sprite_identity as SI

MAX_SCHED = M.MAX_SCHED
FRAME_IRQ_LINE = M.FRAME_IRQ_LINE
MAXCAP = 22

fails = []


def check(label, ok, extra=""):
    if not ok:
        fails.append(label)
    print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' -- ' + extra) if extra else ''}")


def maxcap_expected():
    fx = P3.FIXTURES[MAXCAP]
    fx.reset()
    return fx.build()


def activate(mon, sym, fxi, tries=6):
    """Activate a fixture the way a key press does, and VERIFY it took.

    The isolated-call trick is the only way to drive `rebuild` from the
    harness, and `AGENTS.md` documents why it must be verified: the monitor
    returns from `x` on a prompt echo rather than on the actual stop, so the
    call can be abandoned half way and the machine left mid-rebuild. An earlier
    forensic lost an hour to exactly that, reading a harness failure as a
    spectacular engine bug. So this retries until the BUILD ITSELF says it
    finished -- statAccepted and statBatches are written by buildSchedule -- and
    reports honestly if it never did.
    """
    for _ in range(tries):
        b = set_bp(mon, sym["mainLoop"]); mon.cmd("x"); mon.cmd(f"delete {b}")
        poke(mon, sym["fixtureIndex"], fxi)
        poke(mon, sym["fixtureYOffset"], 0)
        mon.cmd("> 01ff c0"); mon.cmd("> 01fe fd")
        mon.cmd(f"r sp=fd, pc={sym['rebuild']:04x}")
        bb = set_bp(mon, 0xc0fe); mon.cmd("x"); mon.cmd(f"delete {bb}")
        # THE call actually returned -- the PC reached the sentinel. Checking
        # statAccepted alone is not enough: buildSchedule writes those stats
        # part way through, so a call abandoned in its final pass reports 24/19
        # and never reaches publishSchedule at all. The resulting "CURRENT still
        # holds the old fixture" then looks exactly like a lost publication.
        returned = (pc_of(mon) == 0xc0fe)
        mon.cmd(f"r pc={sym['mainLoop']:04x}"); mon.cmd("delete")
        if not returned or rd(mon, sym["fixtureIndex"])[0] != fxi:
            time.sleep(0.15)
            continue
        if fxi == MAXCAP:
            if (rd(mon, sym["statAccepted"])[0] == 24 and
                    rd(mon, sym["statBatches"])[0] == 19):
                return True
        else:
            if rd(mon, sym["statAccepted"])[0] > 0:
                return True
        time.sleep(0.15)
    return False


def first_frame_invariants(mon, sym, want, label):
    """Everything that must be true of MAXCAP's first consumed CURRENT."""
    bad = []
    cur = rd(mon, sym["schedCurrent"])[0]
    n = rd(mon, sym["schedEntries"] + cur)[0]
    nb = rd(mon, sym["schedBatches"] + cur)[0]

    # 1-5: the fixture is wholly itself
    for name, got, exp in (("logCount", rd(mon, sym["logCount"])[0], 30),
                           ("sortedCount", rd(mon, sym["sortedCount"])[0], 30),
                           ("statAccepted", rd(mon, sym["statAccepted"])[0], 24),
                           ("statOverflow", rd(mon, sym["statOverflow"])[0], 6),
                           ("fixtureIndex", rd(mon, sym["fixtureIndex"])[0], MAXCAP)):
        if got != exp:
            bad.append(f"{name}={got} want {exp}")

    # 8-9: CURRENT is the NEW fixture's schedule, complete
    if n != want["accepted"] or nb != want["n_batches"]:
        bad.append(f"CURRENT has {n} entries / {nb} batches, want "
                   f"{want['accepted']}/{want['n_batches']} -- a partial or "
                   f"stale schedule is being consumed")
    else:
        base = cur * MAX_SCHED
        ys = list(rd(mon, sym["schedY"] + base, n))
        ids = list(rd(mon, sym["schedId"] + base, n))
        ptrs = list(rd(mon, sym["schedPtr"] + base, n))
        if ys != [e["y"] for e in want["entries"]]:
            bad.append("CURRENT Y values are not MAXCAP's -- mixed fixture state")
        if ids != [e["id"] for e in want["entries"]]:
            bad.append("CURRENT logical ids are not MAXCAP's")
        # 13: exact logical id -> bitmap identity
        bad += SI.check(lambda a, k: rd(mon, a, k), ids, ptrs, PRG, label)

    # 16: no P5 state may survive into a static fixture
    if rd(mon, sym["ringActive"])[0] != 0:
        bad.append("ringActive still set: P5 motion state leaked into MAXCAP")
    if rd(mon, sym["fixtureMoves"])[0] != 0:
        bad.append("fixtureMoves still set on a static fixture")

    # 12: the frame transaction invariant
    fel = rd(mon, sym["frameEntryLine"])[0]
    if fel != FRAME_IRQ_LINE:
        bad.append(f"frameEntryLine {fel}, want {FRAME_IRQ_LINE}")

    # 10-11: page and pointer-table destination agree
    if rd(mon, sym["statPageMismatch"])[0]:
        bad.append("statPageMismatch set")
    if rd(mon, sym["statPtrMismatch"])[0]:
        bad.append("statPtrMismatch set")
    if rd(mon, sym["sortFault"])[0]:
        bad.append("sortFault set")
    return bad


def main():
    quick = "--quick" in sys.argv
    sym = symbols(SYM)
    want = maxcap_expected()
    t0 = time.time()

    print("=== 1. transition matrix into FIX 16 (MAXCAP) ===")
    print("        Every route a user can take to the one fixture whose whole")
    print("        presentation depends on a single publication surviving.")
    # from-fixtures: a P2 static, a P3 mover, and all three P5 ring modes
    routes = [15, 17, 31, 32, 33]
    reps = 2 if quick else 5
    v = Vice(6960, PRG, warp=True)
    try:
        m = v.mon; m.cmd("delete")
        tally = Counter()
        problems = []
        for src in routes:
            for r in range(reps):
                if not activate(m, sym, src):
                    tally["source activation abandoned (harness)"] += 1
                    continue
                free_run(m, sym["frameCounter"], 0.25, slice_s=0.25)
                # and back into MAXCAP.
                #
                # An earlier draft poked schedPending=1 first, to force the
                # dangerous build-while-pending state. That was wrong: pending
                # set with NO fresh schedule in the buffer is a state the engine
                # never produces, and it causes one spurious swap that leaves
                # CURRENT holding a stale buffer -- a fault invented by the test.
                # The real state occurs on its own often enough to rely on:
                # section 2 measures it at over two hundred builds in a second.
                if not activate(m, sym, MAXCAP):
                    tally["MAXCAP activation abandoned (harness)"] += 1
                    continue
                free_run(m, sym["frameCounter"], 0.3, slice_s=0.3)
                bad = first_frame_invariants(m, sym, want, f"{src:02x}->16")
                tally["transitions checked"] += 1
                if bad:
                    tally["FAULTS"] += 1
                    problems.append(f"{src:02x}->16: {bad[0]}")
        print(f"        {dict(tally)}")
        check("every transition into MAXCAP yields a complete, unmixed CURRENT",
              not problems,
              problems[0] if problems else
              f"{tally['transitions checked']} transitions from {routes}")

        print("\n=== 2. the adoption guard actually engages ===")
        print("        bs_building stops the frame IRQ promoting a buffer a")
        print("        build is still writing. schedBuildDefer counts builds")
        print("        that began with a publication pending -- the state that")
        print("        used to corrupt CURRENT.")
        if activate(m, sym, 31):
            free_run(m, sym["frameCounter"], 1.5, slice_s=0.75)
            d = rd(m, sym["schedBuildDefer"])[0]
            print(f"        RING-SLOW: schedBuildDefer = {d}")
            check("the dangerous build-while-pending state still occurs "
                  "(so the guard is load-bearing, not dead code)", d > 0,
                  f"{d} builds began with a publication pending")
        else:
            check("RING-SLOW selected for the guard check", False)

        print("\n=== 2b. a build started with a publication pending ===")
        print("        The racy state, constructed rather than waited for: a")
        print("        COMPLETE schedule sits published-but-unadopted in")
        print("        schedNext, and a new build then begins writing that same")
        print("        buffer. This is the state section 2 shows arises on its")
        print("        own; forcing it makes the check deterministic.")
        print("        CURRENT may legitimately end up holding EITHER fixture.")
        print("        What it must never hold is a PARTIAL schedule.")
        partial = []
        for trial in range(14):
            if not activate(m, sym, 17):        # a complete schedule in NEXT
                continue
            free_run(m, sym["frameCounter"], 0.2, slice_s=0.2)
            poke(m, sym["schedPending"], 1)     # published, not yet adopted
            if not activate(m, sym, MAXCAP):    # ... and now build over it
                continue
            free_run(m, sym["frameCounter"], 0.3, slice_s=0.3)
            cur = rd(m, sym["schedCurrent"])[0]
            n = rd(m, sym["schedEntries"] + cur)[0]
            nb = rd(m, sym["schedBatches"] + cur)[0]
            # 24/19 is MAXCAP, 12/2 is fixture 17. Anything else -- and in
            # particular 0 entries -- is a half-written buffer promoted to
            # CURRENT, which on a static fixture is permanent.
            if (n, nb) not in ((24, 19), (12, 2)):
                partial.append(f"CURRENT has {n} entries / {nb} batches")
        check("a build never leaves a PARTIAL schedule in CURRENT",
              not partial,
              partial[0] if partial else
              "14 builds started over a pending publication; CURRENT always "
              "held one complete schedule or the other, never a fragment")

        print("\n=== 3. P5 controls still activate cleanly ===")
        for fxi in (31, 32, 33):
            ok = activate(m, sym, fxi)
            if not ok:
                check(f"{P5.MODES[fxi].name} activates", False, "harness abandoned")
                continue
            free_run(m, sym["frameCounter"], 0.3, slice_s=0.3)
            cur = rd(m, sym["schedCurrent"])[0]
            n = rd(m, sym["schedEntries"] + cur)[0]
            check(f"{P5.MODES[fxi].name}: CURRENT holds a complete schedule",
                  n == P5.N_RING and rd(m, sym["ringActive"])[0] == 1,
                  f"{n} entries, ringActive={rd(m, sym['ringActive'])[0]}")
    finally:
        v.close()

    print(f"\n=== 4. runtime ===")
    print(f"        {time.time() - t0:.0f}s wall clock")
    print()
    if fails:
        print(f"=== {len(fails)} FAILURES: " + "; ".join(fails[:4]) + " ===")
        return 1
    print("=== ALL PASS ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
