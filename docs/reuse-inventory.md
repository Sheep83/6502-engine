# 19656 reuse / discard inventory

From inspecting `../shooter_test` and its `/reports` before starting. The point
of the inspection was context, **not** migration: no 19656 renderer code has been
copied into this repository, and none should be.

## Reuse — concepts and knowledge (not code)

| item | why it is worth keeping |
|---|---|
| exact PAL discipline | 19,656 cycles/frame as a hard invariant, and the habit of asserting it |
| VIC bank-0 memory-map constraints | screen A `$0400`, screen B `$2800`, charset `$3800`, char ROM shadow at `$1000-$1fff`, sprite blocks 64-byte aligned |
| **memory-overlap guards** | the score bitmaps silently walked onto the enemy sprite pool because their addresses were *derived from a presentation index*. Guard containment, not just alignment — every bad address there was still 64-byte aligned |
| presentation-deadline diagnostics | the idea of a counter that "must stay 0" (`EDGE_MASK_LATE`) plus a *longest consecutive late run*, which is what a seconds-long glitch looks like |
| framebuffer-vs-model checking | comparing what the VIC presents against a model, rather than trusting screen RAM |
| object semantics | logical object pool, slot 0 = player, Y-sorted active list |
| stage/editor data + level tooling | untouched, still valid, reconnects at P9/P10 |
| player artwork, HUD visual design | the six-digit score, closed heat gauge, lives and upgrade meter designs are good; only their *ownership model* was the problem |
| collision, hitscan, overheat semantics | gameplay rules are sound and independent of the renderer |
| double-buffered screen ownership lessons | page-aware pointer publication is genuinely hard; see `docs/qualification-ladder.md` for how P1 must handle it |
| VICE automation practice | direct background launch, never `open -a`, never steal focus, PID ownership |

## Discard — implementation, without sunk-cost argument

| item | why |
|---|---|
| BUILD/LIVE plan pair and plan-offset addressing | a second double-buffer layered on top of the sorted list |
| `INITIAL_*` snapshot layer | one representation too many |
| `ASSIGN_*` / `BATCH_*` tables | ditto |
| `buildBatchSpriteSchedule` adaptive reuse | chose slots by *search* over `SLOT_FREE_RASTER`; replaced here by `index mod 6` |
| `SLOT_FREE_RASTER` | exists only to support that search |
| the current sorter | replaced later by a persistent order array at P4 |
| the current raster batch implementation | the IRQ made decisions; here it makes none |
| HUD time-domain handoff as implemented | a third owner of the same hardware slots |
| player-layer scheduler | folded into ordinary schedule entries or dedicated slots at P6 |
| sprite pointer publication system | ten writers across two tables; P1 defines one destination per frame |
| renderer fallback paths | unreachable-in-theory paths that hid real failures |

## The measurement that motivated the reset

19656's object→VIC path had **six** software representations and two hardware
pointer tables. Distinct writer sites per shared register:

```
$D015  13      $D010  12      $D01C  11      $2BF8  10
```

Sprite ownership had become a distributed consensus between `renderSprites`,
`hudBorderSetup`, `hudBorderHandoff`, the batch IRQ, `ssFlipMirrorPtrs`, the
player-layer mode code and the lifecycle paths — each correct alone, each holding
a partial view, all racing the beam. This repository exists to not do that again.
