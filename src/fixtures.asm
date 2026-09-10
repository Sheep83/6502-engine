// ===========================================================================
// fixtures.asm — deterministic P0 logical sprite sets
// ===========================================================================
// A fixture is just a list of Y values, pre-sorted ascending. P0 does no
// sorting on purpose: we are proving raster execution, not ordering.
//
// X, pointer and colour are derived from the LOGICAL index, so that a
// mis-assigned pointer or colour is immediately visible as "sprite showing
// numeral 7 is in sprite 3's colour" or "two sprites showing the same numeral".
//
// Expected results are stated per fixture and are asserted by tests/test_p0.py
// against an independent Python model of the builder.
// ===========================================================================

// Indirect indexed addressing REQUIRES a zero-page pointer. Putting fx_src in
// the $1800 segment silently assembled as (zp),y against an unrelated zero-page
// address and loadFixture read garbage. $fb/$fc are free on an unexpanded C64.
.const fx_src = $fb

* = $1800 "fixtures"

.const FIXTURE_COUNT = 5

// --- logical sprite input (what buildSchedule consumes) ---------------------
logCount: .byte 0
logY:     .fill MAX_LOGICAL, 0
logX:     .fill MAX_LOGICAL, 0
logPtr:   .fill MAX_LOGICAL, 0
logCol:   .fill MAX_LOGICAL, 0

// --- fixture Y tables -------------------------------------------------------
// F0: six sprites, comfortably spaced. No reuse at all.
//     expect: accepted 6, reuse 0, rejected 0, batches 1
fixture0: .byte 60, 90, 120, 150, 180, 210
fixture0End:

// F1: seven sprites. Entry 6 is the FIRST reuse and it reuses the slot of
//     entry 0 — the six-slot model. Under an eight-slot model no reuse would
//     occur here at all, which is exactly the bug this fixture guards against.
//     Y values are kept inside the visible window (~50..229): an earlier draft
//     put the seventh sprite at Y=240, in the lower border, so the one thing the
//     fixture exists to show was invisible.
//     expect: accepted 7, reuse 1, rejected 0, batches 2
fixture1: .byte 55, 82, 109, 136, 163, 190, 217
fixture1End:

// F2: fourteen sprites at a uniform 12-line pitch. Same-slot separation is
//     6 x 12 = 72, comfortably legal, so this exercises eight legal reuse
//     events and a nine-batch frame.
//     expect: accepted 14, reuse 8, rejected 0, batches 9
fixture2: .byte 55, 67, 79, 91, 103, 115, 127, 139, 151, 163, 175, 187, 199, 211
fixture2End:

// F3: eight sprites in a 2-line cluster. Entries 6 and 7 would have to share a
//     physical slot with entries 0 and 1 while those are still displaying:
//     PHYSICALLY IMPOSSIBLE. Must be rejected, and the six that fit must render
//     perfectly.
//     expect: accepted 6, reuse 0, rejUnsafe 2, rejMargin 0, batches 1
fixture3: .byte 60, 62, 64, 66, 68, 70, 72, 74
fixture3End:

// F4: the boundary fixture. Six sprites at Y 60..65, then four candidates whose
//     gap against the slot owner (entry 0, Y=60) straddles BOTH thresholds:
//       gap 20 -> UNSAFE            (< SPRITE_HEIGHT: the sprites truly overlap)
//       gap 21 -> CONSERVATIVE      (legal on hardware, inside our safety margin)
//       gap 32 -> CONSERVATIVE      (one line short of the margin)
//       gap 33 -> ACCEPTED          (== MIN_REUSE_GAP)
//     These Y values track MIN_REUSE_GAP; if REUSE_LEAD changes they must move.
//     expect: accepted 7, reuse 1, rejUnsafe 1, rejMargin 2, batches 2
fixture4: .byte 60, 61, 62, 63, 64, 65, 80, 81, 92, 93
fixture4End:

fixtureLo:    .byte <fixture0, <fixture1, <fixture2, <fixture3, <fixture4
fixtureHi:    .byte >fixture0, >fixture1, >fixture2, >fixture3, >fixture4
fixtureLen:   .byte fixture0End - fixture0, fixture1End - fixture1, fixture2End - fixture2
              .byte fixture3End - fixture3, fixture4End - fixture4

.if (fixture2End - fixture2 > MAX_LOGICAL) { .error "fixture 2 exceeds MAX_LOGICAL" }

// ===========================================================================
// loadFixture — copy fixture A into the logical sprite arrays.
// Derives X / pointer / colour from the LOGICAL index so mis-assignment shows.
// ===========================================================================
loadFixture:
    tax
    lda fixtureLo,x
    sta fx_src
    lda fixtureHi,x
    sta fx_src + 1
    lda fixtureLen,x
    sta logCount

    ldy #0
fx_loop:
    cpy logCount
    bcs fx_done
fx_read:
    lda (fx_src),y
    sta logY,y

    // X: seven columns, all < 256 so P0 needs no $D010 bits set
    tya
    and #7
    cmp #7
    bcc !ok+
    lda #0
!ok:
    tax
    lda fxColumnX,x
    sta logX,y

    // pointer: one distinct numbered bitmap per LOGICAL sprite
    tya
    clc
    adc #SPRITE_PTR_FIRST
    sta logPtr,y

    // colour: 1..15, distinct for the first fifteen logical sprites
    tya
    tax
    lda fxColour,x
    sta logCol,y

    iny
    jmp fx_loop
fx_done:
    rts

fxColumnX:  .byte 30, 60, 90, 120, 150, 180, 210
fxColour:   .byte 1,7,13,3,5,14,10,15,2,8,4,12,9,11,6, 1,7,13,3,5,14,10,15,2
