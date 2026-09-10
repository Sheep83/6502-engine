#!/usr/bin/env python3
"""P0 structural + timing tests.

What this proves
----------------
* the schedule the 6502 builder produces matches an INDEPENDENT Python model of
  the documented rules (six-slot round robin, MIN_REUSE_GAP, batch merging);
* accepted / conservatively-rejected / unsafe-rejected counts are as designed;
* hardware slot assignment really is 2..7 and the first reuse happens at
  accepted index 6 (the six-slot model, not eight);
* the schedule fits its allocated memory;
* the executor's per-batch cost, so REUSE_LEAD can be justified rather than
  guessed.

What this does NOT prove
------------------------
Visible correctness. P0 is only GREEN after a human has watched it at normal
speed in VICE. See docs/manual-acceptance.md.

VICE process ownership: this script owns exactly the PIDs it launches, kills
them on success, failure and exception via try/finally, and reaps them.
"""
import os, re, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PRG  = ROOT / "build/engine.prg"
SYM  = ROOT / "build/main.vs"
X64  = "/opt/homebrew/bin/x64sc"
SCRATCH = Path("/tmp/6502-engine-p0")

# --- the documented model, reimplemented independently ----------------------
MUX_FIRST_SLOT = 2
MUX_SLOTS      = 6
SPRITE_HEIGHT  = 21
REUSE_LEAD     = 12
MIN_REUSE_GAP  = SPRITE_HEIGHT + REUSE_LEAD
FRAME_IRQ_LINE = 250
MAX_SCHED      = 24
MAX_BATCH      = 24

FIXTURES = {
    0: [60, 90, 120, 150, 180, 210],
    1: [55, 82, 109, 136, 163, 190, 217],
    2: [55, 67, 79, 91, 103, 115, 127, 139, 151, 163, 175, 187, 199, 211],
    3: [60, 62, 64, 66, 68, 70, 72, 74],
    4: [60, 61, 62, 63, 64, 65, 80, 81, 92, 93],
}

def model(ys):
    sched, unsafe, margin, reuse, cyc = [], 0, 0, 0, 0
    for y in ys:
        if len(sched) >= MUX_SLOTS:
            gap = y - sched[len(sched) - MUX_SLOTS]["y"]
            if gap < SPRITE_HEIGHT:
                unsafe += 1; continue
            if gap < MIN_REUSE_GAP:
                margin += 1; continue
            reuse += 1
        sched.append({"y": y, "slot": MUX_FIRST_SLOT + cyc})
        cyc = (cyc + 1) % MUX_SLOTS
    batches = []
    if sched:
        n0 = min(MUX_SLOTS, len(sched))
        batches.append({"line": FRAME_IRQ_LINE, "first": 0, "count": n0})
        i = n0
        while i < len(sched):
            line = sched[i]["y"] - REUSE_LEAD
            if batches[-1]["line"] == line:
                batches[-1]["count"] += 1
            else:
                batches.append({"line": line, "first": i, "count": 1})
            i += 1
    return sched, unsafe, margin, reuse, batches

# --- VICE monitor -----------------------------------------------------------
import socket
class Monitor:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), 10)
        self.s.settimeout(10)
        time.sleep(0.3); self._drain()
    def _drain(self):
        try:
            while True:
                if not self.s.recv(65536): break
        except Exception:
            pass
    def cmd(self, c, idle=0.30, deadline=4.0):
        """Send a command and collect the reply.

        The VICE remote monitor only emits its "(C:$xxxx)" prompt when the
        machine is stopped, so we cannot wait for it unconditionally. Read until
        the prompt appears OR the socket goes idle -- but never break on a bare
        ">", which begins every memory-dump line and previously truncated
        multi-line replies and desynchronised every following command.
        """
        self.s.sendall((c + "\n").encode())
        out = b""
        end = time.time() + deadline
        self.s.settimeout(idle)
        while time.time() < end:
            try:
                part = self.s.recv(65536)
            except socket.timeout:
                if out: break
                continue
            if not part: break
            out += part
            if b"(C:$" in out: break
        return out.decode(errors="replace")

    def close(self):
        try: self.s.close()
        except Exception: pass

def symbols(path):
    syms = {}
    for line in path.read_text().splitlines():
        m = re.match(r"al C:([0-9a-fA-F]{1,4})\s+\.?(\S+)", line)
        if m: syms[m.group(2)] = int(m.group(1), 16)
    return syms

# Every PID this suite has ever launched. Ownership is by PID, never by
# pattern-matching `pgrep` output: the repository path appears in the command
# line of any manual VICE session the user has open on this project too, and a
# check that cannot tell those apart is one step away from killing one.
LAUNCHED_PIDS = []

class Vice:
    """Owns exactly one x64sc PID and guarantees cleanup."""
    def __init__(self, port, prg, warp=True):
        self.port, self.proc, self.mon = port, None, None
        # Same launch discipline as `make run`: +saveres so a -default run can
        # never write factory settings back over the user's own vicerc, and both
        # joystick devices detached so nothing steals host keys and drives CIA1
        # $DC00/$DC01 -- the registers the fixture-select scan uses.
        args = [X64, "-default", "+saveres", "-pal", "+sound",
                "-joydev1", "0", "-joydev2", "0", "+keyset", "-remotemonitor",
                "-remotemonitoraddress", f"ip4://127.0.0.1:{port}",
                "-autostartprgmode", "1", "-autostart", str(prg)]
        if warp: args.insert(1, "-warp")
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        LAUNCHED_PIDS.append(self.proc.pid)
        print(f"  [vice] launched pid {self.proc.pid} on port {port}")
        time.sleep(4)
        self.mon = Monitor(port)
        # Handshake: the remote monitor silently drops the first commands after
        # connect. Poll until it actually answers before any test logic runs.
        for _ in range(25):
            if "(C:$" in self.mon.cmd("r"): break
            time.sleep(0.3)
        else:
            raise RuntimeError("VICE monitor never became responsive")
    def close(self):
        if self.mon: self.mon.close(); self.mon = None
        if self.proc:
            pid = self.proc.pid
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill(); self.proc.wait(timeout=5)
            print(f"  [vice] reaped pid {pid} (rc={self.proc.returncode})")
            self.proc = None

fails = []
def check(label, ok, extra=""):
    if not ok: fails.append(label)
    print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' -- ' + extra) if extra else ''}")

def set_bp(mon, addr, tries=6):
    """Create a breakpoint and return its id. The remote monitor occasionally
    misses the first command after connect, so retry rather than crash."""
    for _ in range(tries):
        m = re.search(r"BREAK: (\d+)", mon.cmd(f"break {addr:04x}"))
        if m: return m.group(1)
        time.sleep(0.4)
    raise RuntimeError(f"could not set breakpoint at ${addr:04x}")

def rd(mon, a, n=1, tries=6):
    """Read n bytes, VERIFYING the reply is the one we asked for.

    Retrying a short read is not enough: a desynchronised monitor can return a
    complete but STALE dump from an earlier command, which silently yields wrong
    values. So check that the first dump line's address is the one requested,
    and that the reply covers the whole range.
    """
    lo, hi = a & ~0xF, (a + n - 1) | 0xF
    for _ in range(tries):
        reply = mon.cmd(f"m {lo:04x} {hi:04x}")
        rows = re.findall(r">C:([0-9a-f]{4})\s+((?:[0-9a-fA-F]{2}[ ]*)+)", reply)
        if rows and int(rows[0][0], 16) == lo:
            out = []
            for _addr, body in rows:
                out += [int(x, 16) for x in re.findall(r"[0-9a-fA-F]{2}", body)[:16]]
            got = out[a - lo: a - lo + n]
            if len(got) == n:
                return got
        time.sleep(0.25)
    raise RuntimeError(f"could not read ${a:04x}+{n} reliably")

def main():
    SCRATCH.mkdir(exist_ok=True)
    print("=== 0. build artefacts present ===")
    check("build/engine.prg exists", PRG.is_file())
    check("build/main.vs exists", SYM.is_file())
    if fails: return 1
    sym = symbols(SYM)

    print("\n=== 1. static memory-layout invariants ===")
    span = sym["schedCurrent"] - sym["schedY"]
    check("schedule arrays fit the allocated region",
          span <= 0x400, f"{span} bytes of schedule state")
    check("sprite bitmaps are 64-byte aligned", sym["spriteBitmaps"] % 64 == 0,
          f"${sym['spriteBitmaps']:04x}")
    check("sprite bitmaps stay inside VIC bank 0",
          sym["spriteBitmapsEnd"] <= 0x4000, f"${sym['spriteBitmapsEnd']:04x}")

    print("\n=== 2. schedule builder vs independent model ===")
    v = Vice(6510, PRG)
    try:
        mon = v.mon
        mon.cmd("delete")
        # run to the main loop, then take the IRQ out of the picture so the
        # publish/swap cannot race our inspection
        b = set_bp(mon, sym['mainLoop'])
        mon.cmd("x"); mon.cmd(f"delete {b}")
        mon.cmd("> d01a 00")

        nxt = rd(mon, sym["schedNext"])[0]
        base_e = nxt * MAX_SCHED
        base_b = nxt * MAX_BATCH

        for fx, ys in FIXTURES.items():
            m_sched, m_unsafe, m_margin, m_reuse, m_batches = model(ys)
            mon.cmd(f"> {sym['fixtureIndex']:04x} {fx:02x}")
            # isolated call: rebuild leaves the CPU at the RTS sentinel
            mon.cmd("> 01ff c0"); mon.cmd("> 01fe fd")
            mon.cmd(f"r sp=fd, pc={sym['rebuild']:04x}")
            bb = set_bp(mon, 0xc0fe)
            mon.cmd("x"); mon.cmd(f"delete {bb}")

            acc = rd(mon, sym["statAccepted"])[0]
            uns = rd(mon, sym["statRejUnsafe"])[0]
            mar = rd(mon, sym["statRejMargin"])[0]
            reu = rd(mon, sym["statReuse"])[0]
            nb  = rd(mon, sym["statBatches"])[0]

            check(f"F{fx} accepted={acc}", acc == len(m_sched), f"model {len(m_sched)}")
            check(f"F{fx} unsafe-rejected={uns}", uns == m_unsafe, f"model {m_unsafe}")
            check(f"F{fx} margin-rejected={mar}", mar == m_margin, f"model {m_margin}")
            check(f"F{fx} reuse events={reu}", reu == m_reuse, f"model {m_reuse}")
            check(f"F{fx} batches={nb}", nb == len(m_batches), f"model {len(m_batches)}")

            ys_r   = rd(mon, sym["schedY"] + base_e, max(1, acc))[:acc]
            slot_r = rd(mon, sym["schedSlot"] + base_e, max(1, acc))[:acc]
            s2_r   = rd(mon, sym["schedSlot2"] + base_e, max(1, acc))[:acc]
            check(f"F{fx} entry Y values match", ys_r == [e["y"] for e in m_sched],
                  f"{ys_r}")
            check(f"F{fx} slot assignment is the six-slot round robin",
                  slot_r == [e["slot"] for e in m_sched], f"{slot_r}")
            check(f"F{fx} slots stay within 2..7",
                  all(MUX_FIRST_SLOT <= s <= MUX_FIRST_SLOT + MUX_SLOTS - 1 for s in slot_r))
            check(f"F{fx} precomputed slot*2 is consistent",
                  s2_r == [s * 2 for s in slot_r])
            check(f"F{fx} schedule fits MAX_SCHED", acc <= MAX_SCHED)
            check(f"F{fx} batches fit MAX_BATCH", nb <= MAX_BATCH)

            bl = rd(mon, sym["batchLine"] + base_b, max(1, nb))[:nb]
            bf = rd(mon, sym["batchFirst"] + base_b, max(1, nb))[:nb]
            bc = rd(mon, sym["batchCount"] + base_b, max(1, nb))[:nb]
            check(f"F{fx} batch lines match", bl == [b["line"] for b in m_batches], f"{bl}")
            check(f"F{fx} batch first/count match",
                  bf == [b["first"] for b in m_batches] and bc == [b["count"] for b in m_batches],
                  f"first {bf} count {bc}")
            check(f"F{fx} every entry is covered by exactly one batch",
                  sum(bc) == acc, f"covered {sum(bc)} of {acc}")

        # the six-slot model, stated explicitly
        m_sched, *_ = model(FIXTURES[1])
        check("first reuse is accepted index 6 (six-slot, not eight-slot)",
              len(m_sched) == 7 and m_sched[6]["slot"] == MUX_FIRST_SLOT,
              f"entry 6 -> hw slot {m_sched[6]['slot']}")
    finally:
        v.close()

    print("\n=== 3. executor timing (fixture 2, the nine-batch frame) ===")
    v = Vice(6511, PRG)
    log = SCRATCH / "trace.log"
    try:
        mon = v.mon
        mon.cmd("delete")
        b = set_bp(mon, sym['mainLoop'])
        mon.cmd("x"); mon.cmd(f"delete {b}")
        mon.cmd(f"> {sym['fixtureIndex']:04x} 02")
        mon.cmd("> 01ff c0"); mon.cmd("> 01fe fd")
        mon.cmd(f"r sp=fd, pc={sym['rebuild']:04x}")
        bb = set_bp(mon, 0xc0fe)
        mon.cmd("x"); mon.cmd(f"delete {bb}")
        mon.cmd(f"r pc={sym['mainLoop']:04x}")

        nb_live = rd(mon, sym["statBatches"])[0]
        check("timing fixture really has nine batches", nb_live == 9, f"{nb_live}")

        mon.cmd(f'logname "{log}"'); mon.cmd("log on")
        mon.cmd(f"trace exec {sym['irqHandler']:04x}")
        mon.cmd(f"trace exec {sym['exDone']:04x}")
        # Step on the IRQ, NOT on mainLoop: mainLoop is a tight polling loop, so
        # breaking there advances only a few hundred cycles per 'x' and the run
        # never reaches a single batch IRQ.
        bp = set_bp(mon, sym['irqHandler'])
        for _ in range(300):
            mon.cmd("x")
        mon.cmd(f"delete {bp}")
        mon.cmd("log off")
        time.sleep(0.5)

        ev = []
        for m in re.finditer(r"\(Trace  exec ([0-9a-f]{4})\)\s+(\d+)/\$[0-9a-f]+,\s+(\d+)/", log.read_text(errors="replace")):
            ev.append((int(m.group(1), 16), int(m.group(2)), int(m.group(3))))
        # VICE's trace cycle field is the cycle WITHIN the raster line (0..62),
        # not a free-running counter, so convert to an absolute frame position.
        PAL_LINE_CYCLES, PAL_FRAME_CYCLES = 63, 19656
        def pos(line, cyc): return line * PAL_LINE_CYCLES + cyc
        pairs, cur = [], None
        for addr, line, cyc in ev:
            if addr == sym["irqHandler"]: cur = (line, pos(line, cyc))
            elif addr == sym["exDone"] and cur:
                pairs.append((cur[0], (pos(line, cyc) - cur[1]) % PAL_FRAME_CYCLES))
                cur = None
        if pairs:
            costs = [c for _, c in pairs]
            lines = sorted({l for l, _ in pairs})
            worst = max(costs)
            byline = {}
            for l, c in pairs: byline.setdefault(l, []).append(c)
            print(f"        IRQ entry lines observed: {lines}")
            print(f"        handler cost: min {min(costs)}  median {sorted(costs)[len(costs)//2]}"
                  f"  max {worst} cycles ({worst/63:.2f} raster lines)")
            print(f"        frame batch (6 entries, line {FRAME_IRQ_LINE}): "
                  f"{max(byline.get(FRAME_IRQ_LINE, [0]))} cycles")
            single = [c for l, cs in byline.items() if l != FRAME_IRQ_LINE for c in cs]
            if single:
                print(f"        single-entry batch: max {max(single)} cycles")
            check("worst batch cost fits inside the REUSE_LEAD budget",
                  worst <= REUSE_LEAD * 63,
                  f"{worst} cy vs budget {REUSE_LEAD*63} cy ({REUSE_LEAD} lines)")
            check("frame IRQ fires on the documented line",
                  FRAME_IRQ_LINE in lines, f"lines {lines}")
        else:
            check("collected executor timing samples", False, "no trace pairs parsed")
    finally:
        v.close()
        if log.exists(): log.unlink()

    print("\n=== 4. cleanup ===")
    leftovers = list(SCRATCH.glob("*"))
    check("no transient test artefacts left in scratch", not leftovers,
          f"{[p.name for p in leftovers]}")
    r = subprocess.run(["pgrep", "-fl", "x64sc"], capture_output=True, text=True)
    running = {}
    for line in r.stdout.splitlines():
        pid, _, cmd = line.partition(" ")
        try: running[int(pid)] = cmd
        except ValueError: pass
    mine = {pid: cmd for pid, cmd in running.items() if pid in LAUNCHED_PIDS}
    check("no test-owned VICE process remains", not mine, f"{mine}")
    others = {pid: cmd for pid, cmd in running.items() if pid not in LAUNCHED_PIDS}
    print(f"        launched and reaped: {LAUNCHED_PIDS}")
    print(f"        other x64sc processes (NOT ours, left alone): "
          f"{others if others else 'none'}")

    print(f"\n=== {'ALL PASS' if not fails else str(len(fails)) + ' FAILURES: ' + ', '.join(fails[:6])} ===")
    return 1 if fails else 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        try: SCRATCH.rmdir()
        except OSError: pass
