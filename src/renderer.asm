// ===========================================================================
// renderer.asm — P0 sprite multiplexer
// ===========================================================================
// THE ONE SUBSYSTEM THAT OWNS GAMEPLAY SPRITE VIC STATE.
//
// Nothing outside this file writes $D000-$D010, $D015, $D01C, $D027-$D02E or
// the sprite pointer table during the display. That is the whole point.
//
// Shape:
//     logical sprites (pre-sorted by Y in P0)
//         -> buildSchedule (main thread)  writes the NEXT buffer
//         -> publishSchedule              sets a one-byte pending flag
//         -> frame IRQ swaps CURRENT      once, at a frame boundary
//         -> executor consumes CURRENT    immutable for the whole frame
//
// The architectural test: if the main thread stopped dead immediately after
// publishSchedule, the executor would still render the whole frame correctly.
// It reads nothing but the CURRENT schedule.
// ===========================================================================

// --- physical sprite pool ---------------------------------------------------
// Hardware sprites 0 and 1 are RESERVED (player base + overlay in the eventual
// game) and are simply disabled in P0. The gameplay mux pool is 2..7.
.const MUX_FIRST_SLOT = 2
.const MUX_SLOTS      = 6
.const MUX_LAST_SLOT  = MUX_FIRST_SLOT + MUX_SLOTS - 1     // 7

// --- the reuse rule ---------------------------------------------------------
// A VIC sprite with Y = n occupies rasters n .. n+20 (21 lines). The physical
// slot is therefore free from raster n+21.
//
// Accepted entry i reuses the slot of accepted entry i-6 (round robin over six
// slots). Its batch fires REUSE_LEAD lines before its own Y, so the reprogram
// lands at raster (Y_i - REUSE_LEAD) and we need:
//
//     Y_i - REUSE_LEAD  >=  Y_(i-6) + SPRITE_HEIGHT
//     Y_i - Y_(i-6)     >=  SPRITE_HEIGHT + REUSE_LEAD  =  MIN_REUSE_GAP
//
// REUSE_LEAD is MEASURED, not assumed. tests/test_p0.py traces the executor and
// reports its real cost; the first draft of this file guessed 3 lines and the
// test rejected it. Measured on the P0 fixtures:
//
//     single-entry mid-screen batch   277 cycles   (4.4 raster lines)
//     six-entry batch                 666 cycles  (10.6 raster lines)
//
// The executor itself is ~90 cycles of 6502; the rest is VIC cycle theft
// (badline plus sprite DMA on a line with six sprites active). That is exactly
// why this number has to be measured on hardware timing rather than counted
// from a listing.
//
// The builder may merge up to MUX_SLOTS entries into one batch (it happens when
// several accepted sprites share a Y), so the lead must cover the SIX-entry
// case even though the P0 fixtures only produce one-entry batches mid-screen.
// 12 lines = 756 cycles gives 666 plus ~90 cycles of headroom.
//
// NOTE this is deliberately NOT "21 is a magic number". 21 is the hardware
// sprite height; REUSE_LEAD is OUR safety margin and is the only tunable here.
.const SPRITE_HEIGHT   = 21
.const REUSE_LEAD      = 12
.const MIN_REUSE_GAP   = SPRITE_HEIGHT + REUSE_LEAD        // 33

// --- capacities -------------------------------------------------------------
.const MAX_LOGICAL = 24
.const MAX_SCHED   = 24
.const MAX_BATCH   = 24

// The frame IRQ sits in the lower border, so batch 0 (the first up-to-six
// sprites) is programmed before the raster reaches the top of the display —
// the classic "set up the initial sprites in vblank" arrangement.
.const FRAME_IRQ_LINE = 250

// ===========================================================================
// Schedule storage — two buffers, outside VIC bank 0 so it can never be
// mistaken for graphics data.
// ===========================================================================
* = $c000 "schedule buffers"

// per-entry arrays, [buffer][entry]
schedY:      .fill 2 * MAX_SCHED, 0     // sprite Y
schedX:      .fill 2 * MAX_SCHED, 0     // sprite X low byte
schedPtr:    .fill 2 * MAX_SCHED, 0     // sprite pointer value
schedCol:    .fill 2 * MAX_SCHED, 0     // sprite colour
schedSlot:   .fill 2 * MAX_SCHED, 0     // hardware slot 2..7 (explicit: inspectable)
schedSlot2:  .fill 2 * MAX_SCHED, 0     // slot*2, the $D000/$D001 index (no IRQ arithmetic)

// per-batch arrays, [buffer][batch]
batchLine:   .fill 2 * MAX_BATCH, 0     // raster line this batch fires on
batchFirst:  .fill 2 * MAX_BATCH, 0     // first entry index
batchCount:  .fill 2 * MAX_BATCH, 0     // entry count
batchD010:   .fill 2 * MAX_BATCH, 0     // COMPLETE $D010 value after this batch

// per-buffer scalars
schedBatches:  .byte 0, 0               // number of batches in the buffer
schedEnable:   .byte 0, 0               // complete $D015 value for the frame
schedEntries:  .byte 0, 0               // accepted entry count

// --- publication state ------------------------------------------------------
schedCurrent:  .byte 0                  // buffer the EXECUTOR reads
schedNext:     .byte 1                  // buffer the BUILDER writes
schedPending:  .byte 0                  // 1 = swap at the next frame IRQ

// --- diagnostic counters (read by tests; never read by the executor) --------
statAccepted:  .byte 0
statRejUnsafe: .byte 0                  // gap < SPRITE_HEIGHT: genuinely impossible
statRejMargin: .byte 0                  // SPRITE_HEIGHT <= gap < MIN_REUSE_GAP
statReuse:     .byte 0                  // number of slot-reuse events
statBatches:   .byte 0

// --- executor working state -------------------------------------------------
curBatch:      .byte 0
curBase:       .byte 0                  // schedCurrent * MAX_SCHED
curBatchBase:  .byte 0                  // schedCurrent * MAX_BATCH

// ===========================================================================
// buildSchedule — MAIN THREAD ONLY. Writes the NEXT buffer.
// ===========================================================================
// Input: logical sprite arrays (see fixtures.asm), pre-sorted by ascending Y.
//        logCount = number of logical sprites.
// Output: a complete schedule in buffer schedNext, plus the stat counters.
//
// Every decision — acceptance, physical slot, batch line, $D010, $D015 — is
// made HERE. The executor makes none.
// ===========================================================================
* = $1000 "schedule builder"

buildSchedule:
    lda #0
    sta statAccepted
    sta statRejUnsafe
    sta statRejMargin
    sta statReuse
    sta statBatches

    ldx schedNext                       // entry base for this buffer
    lda #0
    cpx #0
    beq !baseDone+
    lda #MAX_SCHED
!baseDone:
    sta bs_base

    lda #0
    sta bs_log                          // logical index
    sta bs_acc                          // accepted count
    sta bs_slotcycle                    // round-robin cursor: MUST reset per build,
                                        // or a rebuild inherits the previous frame's
                                        // slot phase and the schedule stops matching
                                        // the documented "accepted mod 6" rule.

// ---- acceptance pass -------------------------------------------------------
bs_loop:
    lda bs_log
    cmp logCount
    bcc !more+
    jmp bs_accepted_done
!more:

    ldy bs_log
    lda logY,y
    sta bs_y

    lda bs_acc
    cmp #MUX_SLOTS
    bcc bs_accept                       // first six always fit: no slot to reuse

    // Reuse test against the entry that currently owns this physical slot:
    // accepted index (acc - MUX_SLOTS).  <-- SIX, not eight.
    sec
    lda bs_acc
    sbc #MUX_SLOTS
    clc
    adc bs_base
    tay
    lda bs_y
    sec
    sbc schedY,y                        // gap = thisY - ownerY
    bcc bs_unsafe                       // negative: list not sorted / impossible
    cmp #MIN_REUSE_GAP
    bcs bs_accept
    cmp #SPRITE_HEIGHT
    bcs bs_margin                       // 21..23: legal on hardware, inside OUR margin
bs_unsafe:
    inc statRejUnsafe                   // < 21: the two sprites genuinely overlap
    jmp bs_next
bs_margin:
    inc statRejMargin
    jmp bs_next

bs_accept:
    // physical slot = MUX_FIRST_SLOT + (accepted mod MUX_SLOTS)
    lda bs_acc
    cmp #MUX_SLOTS
    bcc !noWrap+
    inc statReuse
!noWrap:
    ldx bs_slotcycle
    lda bs_acc
    clc
    adc bs_base
    tay                                 // Y = schedule entry index (buffer-based)

    txa
    clc
    adc #MUX_FIRST_SLOT
    sta schedSlot,y
    asl
    sta schedSlot2,y

    lda bs_y
    sta schedY,y
    ldx bs_log
    lda logX,x
    sta schedX,y
    lda logPtr,x
    sta schedPtr,y
    lda logCol,x
    sta schedCol,y

    inc bs_slotcycle
    lda bs_slotcycle
    cmp #MUX_SLOTS
    bcc !cycleOk+
    lda #0
    sta bs_slotcycle
!cycleOk:
    inc bs_acc

bs_next:
    inc bs_log
    jmp bs_loop

bs_accepted_done:
    lda bs_acc
    sta statAccepted
    ldx schedNext
    sta schedEntries,x

// ---- enable mask: every slot used by at least one entry --------------------
    lda #0
    sta bs_enable
    lda #0
    sta bs_i
bs_enLoop:
    lda bs_i
    cmp bs_acc
    bcs bs_enDone
    clc
    adc bs_base
    tay
    ldx schedSlot,y
    lda bs_enable
    ora bitMask,x
    sta bs_enable
    inc bs_i
    jmp bs_enLoop
bs_enDone:
    ldx schedNext
    lda bs_enable
    sta schedEnable,x

// ---- batch pass ------------------------------------------------------------
// Batch 0 = the first up-to-MUX_SLOTS entries, programmed by the frame IRQ.
// After that, one batch per entry, merged when two entries need the same line.
    ldx schedNext
    lda #0
    cpx #0
    beq !bbDone+
    lda #MAX_BATCH
!bbDone:
    sta bs_bbase

    lda #0
    sta bs_nb                           // batch count

    lda bs_acc
    beq bs_batchDone

    // batch 0
    ldy bs_bbase
    lda #FRAME_IRQ_LINE
    sta batchLine,y
    lda #0
    sta batchFirst,y
    lda bs_acc
    cmp #MUX_SLOTS
    bcc !small+
    lda #MUX_SLOTS
!small:
    sta batchCount,y
    sta bs_i                            // next entry to place
    inc bs_nb

bs_bLoop:
    lda bs_i
    cmp bs_acc
    bcs bs_batchDone

    // required line for this entry
    clc
    lda bs_i
    adc bs_base
    tay
    lda schedY,y
    sec
    sbc #REUSE_LEAD
    sta bs_line

    // merge into the previous batch if the line matches
    // (INC has no absolute,Y mode, so index the batch arrays with X here)
    lda bs_nb
    sec
    sbc #1
    clc
    adc bs_bbase
    tax
    lda batchLine,x
    cmp bs_line
    bne bs_newBatch
    inc batchCount,x
    jmp bs_bNext

bs_newBatch:
    lda bs_nb
    cmp #MAX_BATCH
    bcs bs_batchDone                    // out of batch slots: stop (guarded by test)
    clc
    adc bs_bbase
    tay
    lda bs_line
    sta batchLine,y
    lda bs_i
    sta batchFirst,y
    lda #1
    sta batchCount,y
    inc bs_nb

bs_bNext:
    inc bs_i
    jmp bs_bLoop

bs_batchDone:
    lda bs_nb
    sta statBatches
    ldx schedNext
    sta schedBatches,x

// ---- precompute the COMPLETE $D010 after each batch ------------------------
// One store per batch in the executor, no read-modify-write, no shared-register
// race. Start from 0 (P0 fixtures are all X < 256) and accumulate forwards.
    lda #0
    sta bs_d010
    lda #0
    sta bs_b
bs_dLoop:
    lda bs_b
    cmp bs_nb
    bcs bs_dDone
    clc
    adc bs_bbase
    tay
    lda batchFirst,y
    sta bs_i
    lda batchCount,y
    sta bs_n
bs_dEntry:
    lda bs_n
    beq bs_dStore
    clc
    lda bs_i
    adc bs_base
    tay
    ldx schedSlot,y
    lda schedX,y                        // P0: all X < 256, so clear the bit
    lda bs_d010
    and bitMaskInv,x
    sta bs_d010
    inc bs_i
    dec bs_n
    jmp bs_dEntry
bs_dStore:
    lda bs_b
    clc
    adc bs_bbase
    tay
    lda bs_d010
    sta batchD010,y
    inc bs_b
    jmp bs_dLoop
bs_dDone:
    rts

// ===========================================================================
// publishSchedule — the ONLY handover point. One byte, atomic.
// ===========================================================================
publishSchedule:
    lda #1
    sta schedPending
    rts

// --- builder locals (main thread only; the executor never touches these) ----
bs_base:      .byte 0
bs_bbase:     .byte 0
bs_log:       .byte 0
bs_acc:       .byte 0
bs_i:         .byte 0
bs_n:         .byte 0
bs_b:         .byte 0
bs_nb:        .byte 0
bs_y:         .byte 0
bs_line:      .byte 0
bs_enable:    .byte 0
bs_d010:      .byte 0
bs_slotcycle: .byte 0

bitMask:      .byte $01,$02,$04,$08,$10,$20,$40,$80
bitMaskInv:   .byte $fe,$fd,$fb,$f7,$ef,$df,$bf,$7f

// ===========================================================================
// The executor. Consumes CURRENT only.
// ===========================================================================
* = $1500 "raster executor"

irqHandler:
    pha
    txa
    pha
    tya
    pha
    lda #$01
    sta $d019                           // acknowledge the raster IRQ

    lda curBatch
    bne exBatch

// ---- frame boundary: swap, set frame-wide state, run batch 0 --------------
exFrame:
    lda schedPending
    beq !noSwap+
    lda #0
    sta schedPending
    lda schedCurrent                    // swap CURRENT <-> NEXT
    ldx schedNext
    stx schedCurrent
    sta schedNext
!noSwap:
    // cache the buffer bases once per frame
    lda #0
    ldx schedCurrent
    beq !zero+
    lda #MAX_SCHED
!zero:
    sta curBase
    lda #0
    cpx #0
    beq !zero2+
    lda #MAX_BATCH
!zero2:
    sta curBatchBase

    ldx schedCurrent
    lda schedEnable,x
    sta $d015                           // one writer, once per frame
    lda #$00
    sta $d01c                           // P0: all mux sprites hires

// ---- batch executor --------------------------------------------------------
exBatch:
    lda curBatch
    ldx schedCurrent
    cmp schedBatches,x
    bcs exEndFrame                      // no more batches this frame

    clc
    adc curBatchBase
    tay
    lda batchFirst,y
    sta ex_i
    lda batchCount,y
    sta ex_n
    lda batchD010,y
    sta ex_d010

exEntry:
    lda ex_n
    beq exEntriesDone
    clc
    lda ex_i
    adc curBase
    tay

    ldx schedSlot2,y                    // precomputed slot*2
    lda schedY,y
    sta $d001,x                         // Y FIRST: it is the only timing-critical write
    lda schedX,y
    sta $d000,x
    ldx schedSlot,y
    lda schedCol,y
    sta $d027,x
    lda schedPtr,y
    sta SPRITE_PTR_BASE,x               // P0: single screen page, single destination

    inc ex_i
    dec ex_n
    jmp exEntry

exEntriesDone:
    lda ex_d010
    sta $d010                           // complete value, one store, no RMW

    inc curBatch

// ---- arm the next event ----------------------------------------------------
    lda curBatch
    ldx schedCurrent
    cmp schedBatches,x
    bcs exArmFrame
    clc
    adc curBatchBase
    tay
    lda batchLine,y
    jmp exArm

exEndFrame:
exArmFrame:
    lda #0
    sta curBatch
    lda #FRAME_IRQ_LINE

exArm:
    sta $d012
    // Late-IRQ recovery, the historical pattern: if the beam is already at or
    // past the line we just armed, the IRQ would not fire until the next frame.
    // Run the batch immediately instead.
    cmp $d012
    bcc exLate
    jmp exDone
exLate:
    lda curBatch
    beq exDone                          // frame batch: never chase it mid-frame
    jmp exBatch

exDone:
    pla
    tay
    pla
    tax
    pla
    rti

ex_i:    .byte 0
ex_n:    .byte 0
ex_d010: .byte 0

// ===========================================================================
// installRenderer — set up the IRQ chain. Called once from main.
// ===========================================================================
installRenderer:
    sei
    lda #$7f
    sta $dc0d                           // no CIA timer IRQs
    lda $dc0d
    lda #$35
    sta $01                             // KERNAL out: our vector at $fffe
    lda #<irqHandler
    sta $fffe
    lda #>irqHandler
    sta $ffff
    lda #$01
    sta $d01a                           // enable raster IRQ
    lda #$01
    sta $d019
    lda $d011
    and #$7f
    sta $d011                           // raster compare high bit = 0
    lda #FRAME_IRQ_LINE
    sta $d012
    lda #0
    sta curBatch
    sta $d015                           // sprites off until the first frame IRQ
    cli
    rts
