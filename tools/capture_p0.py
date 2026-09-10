#!/usr/bin/env python3
"""Capture one screenshot per P0 fixture.

Runs under WARP deliberately. Any monitor command halts the emulator, so a
harness cannot observe a freely-running non-warp machine: between "x" and the
next command almost no emulated time passes and the frame IRQ never runs. Warp
changes only how much emulated time elapses per monitor round trip -- it does
not change renderer behaviour.

This is an AID to the manual acceptance procedure, never a substitute for it.
The authoritative test is a human watching a non-warp run (docs/manual-acceptance.md).
Owns and reaps its VICE PID.

Usage: tools/capture_p0.py [outdir]   (default /tmp/6502-engine-shots)
"""
import sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from test_p0 import symbols, Vice, set_bp, rd

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/6502-engine-shots")
OUT.mkdir(parents=True, exist_ok=True)
sym = symbols(ROOT / "build/main.vs")

v = Vice(6530, ROOT / "build/engine.prg", warp=True)
try:
    m = v.mon
    m.cmd("delete")
    b = set_bp(m, sym["mainLoop"]); m.cmd("x"); m.cmd(f"delete {b}")
    for fx in range(5):
        # Always come to rest at mainLoop before hijacking the CPU. Stopping
        # inside the IRQ handler and then setting PC leaves the I flag SET (we
        # never RTI), so interrupts never fire again and the schedule swap
        # silently stops happening. That cost an hour; do not remove this.
        b = set_bp(m, sym["mainLoop"]); m.cmd("x"); m.cmd(f"delete {b}")
        m.cmd(f"> {sym['fixtureIndex']:04x} {fx:02x}")
        assert rd(m, sym["fixtureIndex"])[0] == fx, "fixture write did not land"
        m.cmd("> 01ff c0"); m.cmd("> 01fe fd")
        m.cmd(f"r sp=fd, pc={sym['rebuild']:04x}")
        bb = set_bp(m, 0xc0fe); m.cmd("x"); m.cmd(f"delete {bb}")
        acc = rd(m, sym["statAccepted"])[0]
        nb  = rd(m, sym["statBatches"])[0]
        # Let the machine RUN in real time. Stepping IRQ-by-IRQ under non-warp
        # proved unreliable; free-running for a few frames is both simpler and
        # closer to what a human sees.
        m.cmd(f"r pc={sym['mainLoop']:04x}")
        # Advance emulated time by stepping the IRQ. Sleeping does not work:
        # the next monitor command halts the machine, so the captured frame
        # would still be the previous fixture's.
        bp = set_bp(m, sym["irqHandler"])
        for _ in range(40): m.cmd("x")
        m.cmd(f"delete {bp}")
        cur = rd(m, sym["schedCurrent"])[0]
        m.cmd(f'screenshot "{OUT}/f{fx}.png" 2')
        time.sleep(0.6)
        print(f"  fixture {fx}: accepted {acc}, batches {nb} -> f{fx}.png"
              f"   [cur={cur} pending={rd(m,sym['schedPending'])[0]} "
              f"entries[cur]={rd(m,sym['schedEntries']+cur)[0]} "
              f"spr2Y={rd(m,0xd005)[0]} spr7Y={rd(m,0xd00f)[0]} d015=${rd(m,0xd015)[0]:02x}]")
finally:
    v.close()
print(f"screenshots in {OUT}")
