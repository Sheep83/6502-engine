// ===========================================================================
// scroll.asm — P1 deterministic vertical scroller
// ===========================================================================
// The smallest scroller that genuinely exercises C64 vertical scrolling:
// every fine-scroll phase, a coarse row step, and a real screen-page flip.
// It is a diagnostic surface, not artwork.
//
// SHAPE
//   main thread          decides the NEXT frame and writes a frame record
//       |                (fine scroll, $d018, pointer-table destination, page)
//       v
//   framePending = 1     one byte, exactly like schedPending
//       v
//   frame IRQ            adopts the record ONCE, in the lower border, and is
//                        the only thing that writes $d011/$d018/the pointer
//                        destination. See exFrame in renderer.asm.
//
// The executor never asks the scroller anything. Everything it needs for the
// whole displayed frame was latched at the frame boundary.
//
// GEOMETRY
// Page P displays world rows [worldRow .. worldRow+24]. The fine scroll counts
// DOWN 7..0, moving the playfield up one pixel per frame. On the 0 -> 7 wrap
// the content must jump up one whole row, so worldRow advances and we flip to
// the other page, which has been prepared with world rows [worldRow+1 .. +25].
// Coarse step and page flip are therefore the SAME event, once every 8 frames.
//
// WHY THE BACK PAGE IS REGENERATED, NOT COPIED
// Every row is written from its own world row number, so a stale row, a
// duplicated row or a one-row jump cannot survive: the row prints its own
// identity. A copy-and-shift would reproduce whatever was already wrong.
// ===========================================================================

.const ROWS_PER_TICK = 5                // 25 rows over the 8 frames between
                                        // coarse steps, with margin. Spread on
                                        // purpose: a single 25-row burst is
                                        // ~12,000 cycles of the 19,656 in a
                                        // frame, which leaves no room for
                                        // anything else the main thread grows.

// $1a00, not $1900: the P2 fixture tables grew the `fixtures` segment to
// $199e. Everything from $1000 to $1fff is behind the VIC's character-ROM
// shadow and so invisible to the VIC either way; the only constraint is that
// this segment must still end below the sprite bitmaps at $2000.
* = $1a00 "scroller"

// --- scroll state. MAIN THREAD ONLY. The executor never reads any of this. --
scrollFine:   .byte 0                   // current YSCROLL, counts 7..0
worldRowLo:   .byte 0                   // world row shown at screen row 0
worldRowHi:   .byte 0
dispPage:     .byte 0                   // 0 = A, 1 = B. The page to display NEXT.
regenPage:    .byte 0                   // page currently being rebuilt
regenPageHi:  .byte 0                   // its high byte ($04 or $28)
regenRow:     .byte 0                   // next screen row to rebuild (25 = idle)
regenWorldLo: .byte 0                   // world row of regen screen row 0
rrWorld:      .byte 0                   // scratch: world row of the row in hand
hudPageHi:    .byte 0                   // high byte of the page the HUD writes to

// --- diagnostics read by tests ---------------------------------------------
coarseCount:  .byte 0, 0                // coarse row steps (16-bit, lo/hi)
finePhase:    .fill 16, 0               // frames spent at each YSCROLL value,
                                        // 16-bit per phase (lo,hi). An 8-bit
                                        // counter wraps after 256 frames per
                                        // phase, which is ~34 seconds -- far
                                        // shorter than a stress run, and it
                                        // silently under-reports coverage.
scrollLate:   .byte 0                   // coarse step arrived with the back
                                        // page unfinished: a real fault
publishSkip:  .byte 0                   // publication found the previous one
                                        // still unadopted: a real fault

// --- P2 pinned fine phase: a DIAGNOSTIC MODE, not a second scroller --------
// For automated qualification only. With pinFine non-zero the fine scroll is
// HELD at pinFineValue instead of counting down, so the same sprite geometry
// can be measured against each of the eight badline alignments in turn.
//
// Holding the phase necessarily suspends the coarse step and the page flip:
// they ARE the fine-scroll wrap (see GEOMETRY above), so there is nothing left
// to trigger them. That is the whole reason natural scrolling has to be
// restored and the geometry re-proven across real coarse steps and page flips
// before any phase result is believed.
//
// Nothing else changes. publishFrame still builds and hands over the frame
// record exactly as it always does, so $d011 carries the pinned phase through
// the ordinary published channel and the executor cannot tell the difference.
// A test therefore verifies the phase from $d011 on the running machine, never
// from this variable.
pinFine:      .byte 0                   // 0 = natural scrolling, 1 = held
pinFineValue: .byte 0                   // the YSCROLL to hold, 0..7

// ===========================================================================
// scrollInit — both pages built, page A displayed, frame 0 published.
// ===========================================================================
scrollInit:
    lda #7
    sta scrollFine
    lda #0
    sta worldRowLo
    sta worldRowHi
    sta dispPage                        // page A displays world rows 0..24

    lda #0
    sta regenPage
    lda #>SCREEN_A
    sta regenPageHi
    lda #0
    sta regenWorldLo
    jsr regenAll

    lda #1
    sta regenPage                       // page B holds world rows 1..25, ready
    lda #>SCREEN_B                      // for the first coarse step
    sta regenPageHi
    lda #1
    sta regenWorldLo
    jsr regenAll

    lda #SCREEN_ROWS
    sta regenRow                        // idle until the first coarse step
    jsr publishFrame
    rts

regenAll:
    lda #0
    sta regenRow
!loop:
    jsr renderRow
    inc regenRow
    lda regenRow
    cmp #SCREEN_ROWS
    bcc !loop-
    rts

// ===========================================================================
// scrollTick — one call per displayed frame. Advances the scroll and publishes
// the frame record the NEXT frame IRQ will adopt.
// ===========================================================================
scrollTick:
    lda pinFine                         // P2 diagnostic mode: hold the phase
    beq !natural+
    lda pinFineValue
    and #7
    sta scrollFine
    jmp scrollPublish
!natural:
    dec scrollFine
    bpl scrollPublish

// ---- coarse step: advance the world, flip the page ------------------------
    lda #7
    sta scrollFine

    lda regenRow                        // the page we are about to display was
    cmp #SCREEN_ROWS                    // not finished. Never expected; counted
    bcs !ready+                         // rather than hidden. Saturates.
    lda scrollLate
    cmp #$ff
    beq !ready+
    inc scrollLate
!ready:
    inc worldRowLo
    bne !nohi+
    inc worldRowHi
!nohi:
    lda dispPage
    eor #1
    sta dispPage                        // flip to the page prepared last time
    eor #1
    sta regenPage                       // the page we just left is now the back

    lda regenPage
    bne !pb+
    lda #>SCREEN_A
    jmp !ps+
!pb:
    lda #>SCREEN_B
!ps:
    sta regenPageHi

    lda worldRowLo                      // the back page gets the row after the
    clc                                 // one now on screen
    adc #1
    sta regenWorldLo
    lda #0
    sta regenRow                        // start rebuilding it next frame

    inc coarseCount
    bne scrollPublish
    inc coarseCount+1

scrollPublish:
    lda scrollFine
    asl                                 // two bytes per phase
    tax
    inc finePhase,x
    bne !counted+
    inc finePhase + 1,x
!counted:
    // fall through

// ===========================================================================
// publishFrame — write the NEXT frame record and hand it over with one byte.
// Double buffered for the same reason the schedule is: the frame IRQ must
// never see a half-updated set where $d018 says one page and the pointer
// destination says the other.
// ===========================================================================
publishFrame:
    lda framePending
    beq !free+
    lda publishSkip                     // previous record not adopted yet
    cmp #$ff
    beq !skipped+
    inc publishSkip
!skipped:
    rts
!free:
    ldx frameNext
    lda #D011_BASE
    ora scrollFine
    sta frameD011,x
    lda dispPage
    sta framePage,x
    bne !pageB+
    lda #D018_A
    sta frameD018,x
    lda #>PTR_A
    sta framePtrHi,x
    jmp !armed+
!pageB:
    lda #D018_B
    sta frameD018,x
    lda #>PTR_B
    sta framePtrHi,x
!armed:
    lda #1
    sta framePending                    // the handover. One byte, atomic.
    rts

// ===========================================================================
// regenTick — rebuild a few rows of the back page, once per frame.
// ===========================================================================
regenTick:
    lda regenRow
    cmp #SCREEN_ROWS
    bcs !done+
    ldy #ROWS_PER_TICK
!loop:
    tya
    pha
    jsr renderRow
    pla
    tay
    inc regenRow
    lda regenRow
    cmp #SCREEN_ROWS
    bcs !done+
    dey
    bne !loop-
!done:
    rts

// ===========================================================================
// renderRow — rebuild screen row `regenRow` of the back page.
// HUD rows are drawn by the HUD code so the page is COMPLETE when it flips;
// otherwise the newly displayed page would show background where the status
// lines belong for one frame out of every eight.
// ===========================================================================
renderRow:
    ldx regenRow
    lda rowLo,x
    sta scrPtr
    lda rowHi,x
    clc
    adc regenPageHi
    sta scrPtr + 1

    cpx #HUD_ROW_STATS
    beq !hud+
    cpx #HUD_ROW_SCROLL
    beq !hud+
    cpx #HUD_ROW_P3
    beq !hud+
    cpx #HUD_ROW_P2
    beq !hud+
    cpx #HUD_ROW_FIX
    beq !hud+
    jmp renderBackgroundRow
!hud:
    jmp drawHudRow                      // X = row, scrPtr = destination

// ---------------------------------------------------------------------------
// renderBackgroundRow — the diagnostic pattern for one world row.
//
//   cols 0-1   world row number, low byte, in hex   <- row identity
//   col  2     space
//   col  3     'A' or 'B', the page this row was written into
//   col  4     space
//   cols 5-39  solid bar every 4th world row, blank otherwise
//   col  6+(W and 31)   a '*' marker, so each row is distinguishable even
//                       inside a run of blank rows
//
// A duplicated row, a stale row, a skipped row or a torn page flip all show up
// immediately: the hex column must count by one, every row on screen must
// carry the SAME page letter, and the marker must walk a clean diagonal.
// ---------------------------------------------------------------------------
renderBackgroundRow:
    txa                                 // X still = regenRow
    clc
    adc regenWorldLo
    sta rrWorld

    and #3
    bne !blank+
    lda #$a0                            // reverse space: a solid bar
    jmp !fill+
!blank:
    lda #$20
!fill:
    ldy #39
!f:
    sta (scrPtr),y
    dey
    cpy #4
    bne !f-

    lda rrWorld                         // the walking marker
    and #31
    clc
    adc #6
    tay
    lda #42                             // '*'
    sta (scrPtr),y

    lda rrWorld                         // row identity in hex
    lsr
    lsr
    lsr
    lsr
    tax
    lda hexDigit,x
    ldy #0
    sta (scrPtr),y
    lda rrWorld
    and #$0f
    tax
    lda hexDigit,x
    ldy #1
    sta (scrPtr),y

    lda #$20
    ldy #2
    sta (scrPtr),y
    ldy #4
    sta (scrPtr),y
    lda regenPage                       // which page this row was built into
    clc
    adc #1                              // screen code 1 = 'A', 2 = 'B'
    ldy #3
    sta (scrPtr),y
    rts

// --- screen row byte offsets, so a row address is one add, never a multiply -
rowLo: .fill SCREEN_ROWS, <(i * 40)
rowHi: .fill SCREEN_ROWS, >(i * 40)
