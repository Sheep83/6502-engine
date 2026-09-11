#!/usr/bin/env python3
"""The P2 independent model of buildSchedule, with full provenance.

test_p0.py's `model()` answers "how many were accepted and where do the batches
fire". P2 has to answer harder questions -- WHICH entry owns a slot, WHICH
predecessor a candidate was tested against, what the reuse gap actually was,
and why a particular sprite was rejected -- so this reimplements the documented
rules a second time, from the rules themselves rather than from the 6502.

It is deliberately a separate file from the assembler and from test_p0's model:
two independent statements of the same rule that must agree with the machine.
"""

MUX_FIRST_SLOT = 2
MUX_SLOTS      = 6
SPRITE_HEIGHT  = 21
REUSE_LEAD     = 12
MIN_REUSE_GAP  = SPRITE_HEIGHT + REUSE_LEAD      # 33
FRAME_IRQ_LINE = 250
MAX_SCHED      = 24
MAX_BATCH      = 24
MAX_LOGICAL    = 24
PAL_LINES      = 312
PAL_CYCLES     = 63

# Classification vocabulary. Every case must end as exactly one of these, and
# the first three are all CORRECT outcomes -- only the last two are bugs.
LEGAL_RENDERED     = "legal-and-rendered"
LEGAL_REJECTED     = "legal-but-conservatively-rejected"
UNSAFE_REJECTED    = "physically-unsafe-and-rejected"
RENDERER_FAILURE   = "renderer-failure"
HARNESS_FAILURE    = "harness-failure"


def build(ys, y_offset=0):
    """Model buildSchedule for a logical Y list.

    Returns a dict carrying everything the engine can be asked for, so a test
    can compare field by field instead of comparing summary counts and hoping.

    `y_offset` is added with 8-bit wrap, exactly as loadFixture's ADC does.
    """
    ys = [(y + y_offset) & 0xff for y in ys]

    entries, rejects, cyc = [], [], 0
    for li, y in enumerate(ys):
        pred = None
        if len(entries) >= MUX_SLOTS:
            pred = entries[len(entries) - MUX_SLOTS]
            gap = y - pred["y"]
            # The 6502 does SBC and branches on carry: a negative result means
            # the list was not sorted ascending, and it lands in the unsafe
            # arm. Model that rather than the tidier abs().
            if gap < 0 or gap < SPRITE_HEIGHT:
                rejects.append({"log": li, "y": y, "gap": gap,
                                "pred_y": pred["y"], "pred_acc": pred["acc"],
                                "reason": "unsafe", "verdict": UNSAFE_REJECTED})
                continue
            if gap < MIN_REUSE_GAP:
                rejects.append({"log": li, "y": y, "gap": gap,
                                "pred_y": pred["y"], "pred_acc": pred["acc"],
                                "reason": "margin", "verdict": LEGAL_REJECTED})
                continue

        entries.append({
            "log": li, "acc": len(entries), "y": y,
            "slot": MUX_FIRST_SLOT + cyc,
            "slot2": (MUX_FIRST_SLOT + cyc) * 2,
            "pred_acc": pred["acc"] if pred else None,
            "pred_y":   pred["y"]   if pred else None,
            "gap":      (y - pred["y"]) if pred else None,
            "is_reuse": pred is not None,
        })
        cyc = (cyc + 1) % MUX_SLOTS

    batches = []
    if entries:
        n0 = min(MUX_SLOTS, len(entries))
        batches.append({"line": FRAME_IRQ_LINE, "first": 0, "count": n0,
                        "frame": True})
        i = n0
        while i < len(entries):
            line = (entries[i]["y"] - REUSE_LEAD) & 0xff
            if batches[-1]["line"] == line and not batches[-1].get("frame"):
                batches[-1]["count"] += 1
            elif batches[-1]["line"] == line and batches[-1].get("frame"):
                # A mid-screen entry whose line collides with FRAME_IRQ_LINE
                # would merge into batch 0 in the 6502 too: it compares only
                # the previous batch's line. Kept explicit so the model does
                # not quietly diverge if a sweep ever reaches Y = 262.
                batches[-1]["count"] += 1
            else:
                batches.append({"line": line, "first": i, "count": 1,
                                "frame": False})
            i += 1

    mid = [b for b in batches if not b.get("frame")]
    return {
        "ys": ys,
        "entries": entries,
        "rejects": rejects,
        "batches": batches,
        "mid_batches": mid,
        "accepted": len(entries),
        "rej_unsafe": sum(1 for r in rejects if r["reason"] == "unsafe"),
        "rej_margin": sum(1 for r in rejects if r["reason"] == "margin"),
        "reuse": sum(1 for e in entries if e["is_reuse"]),
        "n_batches": len(batches),
        "max_mid_batch": max([b["count"] for b in mid], default=0),
        "over_sched": len(entries) > MAX_SCHED,
        "over_batch": len(batches) > MAX_BATCH,
    }


def classify(case):
    """Per-logical-sprite classification, one verdict each."""
    out = {}
    for e in case["entries"]:
        out[e["log"]] = LEGAL_RENDERED
    for r in case["rejects"]:
        out[r["log"]] = r["verdict"]
    return out


def badlines_in(first_line, last_line, yscroll):
    """Rasters in [first,last] on which the VIC steals a badline.

    A badline is raster in 48..247 with (raster & 7) == YSCROLL, given DEN=1.
    It costs the CPU ~40-43 cycles, and on a 12-line reuse window there is
    always at least one, which is why the phase sweep exists.
    """
    return [r for r in range(first_line, last_line + 1)
            if 48 <= r <= 247 and (r & 7) == (yscroll & 7)]


def deadline_cycles():
    """The mid-screen reuse budget, in cycles, from the ARMED line.

    The batch is armed for raster Yc - REUSE_LEAD and the sprite must be
    programmed before the VIC fetches it. Two readings are reported because
    they answer different questions:

      display : Yc      -> REUSE_LEAD * 63       = 756  (the documented budget)
      fetch   : Yc - 1  -> (REUSE_LEAD - 1) * 63 = 693  (the stricter one: the
                VIC fetches a sprite's data on the line BEFORE it displays)
    """
    return REUSE_LEAD * PAL_CYCLES, (REUSE_LEAD - 1) * PAL_CYCLES


# --- the P2 named fixtures, restated independently of fixtures.asm ----------
# These duplicate the assembler on purpose. If someone edits one table and not
# the other, the suite fails loudly instead of testing the edit against itself.
P2_LEAD_Y   = 60
P2_MERGE_Y  = P2_LEAD_Y + 5 + MIN_REUSE_GAP          # 98
_B          = [P2_LEAD_Y + i for i in range(6)]

NAMED = {
    0:  ("F0 no reuse",            [60, 90, 120, 150, 180, 210]),
    1:  ("F1 first reuse",         [55, 82, 109, 136, 163, 190, 217]),
    2:  ("F2 repeated reuse",      [55 + 12 * i for i in range(14)]),
    3:  ("F3 unsafe cluster",      [60, 62, 64, 66, 68, 70, 72, 74]),
    4:  ("F4 P0 boundary walk",    [60, 61, 62, 63, 64, 65, 80, 81, 92, 93]),
    5:  ("T6 six-entry merged",    _B + [P2_MERGE_Y] * 6),
    6:  ("T5 five-entry merged",   _B + [P2_MERGE_Y] * 5),
    7:  ("T4 four-entry merged",   _B + [P2_MERGE_Y] * 4),
    8:  ("T3 three-entry merged",  _B + [P2_MERGE_Y] * 3),
    9:  ("T2 two-entry merged",    _B + [P2_MERGE_Y] * 2),
    10: ("T1 one-entry control",   _B + [P2_MERGE_Y] * 1),
    11: ("SPLIT merge boundary",   _B + [P2_MERGE_Y, P2_MERGE_Y + 1]),
    12: ("BNDPHYS gap 20/21",      _B + [P2_LEAD_Y + SPRITE_HEIGHT - 1,
                                         P2_LEAD_Y + SPRITE_HEIGHT]),
    13: ("BNDCONS gap 32/33",      _B + [P2_LEAD_Y + MIN_REUSE_GAP - 1,
                                         P2_LEAD_Y + MIN_REUSE_GAP]),
    14: ("T6X3 three merged sixes", _B + [P2_MERGE_Y] * 6
                                       + [P2_MERGE_Y + 38] * 6
                                       + [P2_MERGE_Y + 76] * 6),
    # The worst measured legal geometry, frozen as literal Y values: the T6
    # geometry shifted down 8 rasters, which puts the merged batch on raster 94.
    # Measured, not chosen -- see reports/p2-static-y-stress-matrix-report.md.
    15: ("WORST measured legal",   [P2_LEAD_Y + 8 + i for i in range(6)]
                                   + [P2_MERGE_Y + 8] * 6),
}

# The uniform-spacing axis required by docs/p2-static-y-matrix.md. Uniform
# pitch S gives a SAME-SLOT separation of 6*S, so every one of these is
# comfortably legal -- which is the point: it demonstrates that the uniform
# axis does not test the reuse rule at all, and that the clustered axis is the
# one that does.
UNIFORM_SPACINGS = [30, 24, 22, 21, 20, 18, 16, 12]
UNIFORM_START_Y  = 55
UNIFORM_LAST_Y   = 229


def uniform(spacing, start=UNIFORM_START_Y, last=UNIFORM_LAST_Y):
    n = min(MAX_LOGICAL, (last - start) // spacing + 1)
    return [start + spacing * i for i in range(n)]
