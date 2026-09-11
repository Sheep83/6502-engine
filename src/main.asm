// ===========================================================================
// 6502-engine — P1: scrolling double-buffered playfield + P0 sprite fixtures
// ===========================================================================
// PAL Commodore 64. 19,656 cycles per frame. Legal NMOS 6502/6510 only.
// KickAssembler 5.25.
//
// P0 proved: a prepared logical sprite set is displayed deterministically
// through six hardware mux slots from a complete immutable schedule.
//
// P1 proves ONE thing more:
//   that stays true while a real vertically scrolling, double-buffered
//   playfield runs underneath it — every fine-scroll phase, repeated coarse
//   steps, repeated screen-page flips, and exactly ONE sprite-pointer-table
//   destination per displayed frame, always the one $d018 is showing.
//
// Still no player, no sorter, no collision, no AI, no HUD raster split, no
// border opening. All five P0 fixtures remain independently runnable.
//
// Controls: SPACE cycles the fixture. VICE must be launched with the joystick
// devices detached or a keyset will swallow the key — see readNextFixture and
// VICE_OPTS in the Makefile. The fixture index is also pokeable at
// `fixtureIndex` so automated tests can select one without keyboard input.
// ===========================================================================

// --- VIC bank 0 memory map --------------------------------------------------
//   $0400-$07ff   screen page A          sprite pointers $07f8-$07ff
//   $0810-$1fff   our code               VIC sees the CHARACTER ROM at
//                                        $1000-$1fff, so code living there is
//                                        invisible to the VIC. This is the
//                                        stock C64 arrangement, not a trick.
//   $2000-$23ff   sprite bitmaps (16 x 64)
//   $2800-$2bff   screen page B          sprite pointers $2bf8-$2bff
//   $c000-...     schedule + frame records, OUTSIDE bank 0 by design
.const SCREEN_A       = $0400
.const SCREEN_B       = $2800
.const PTR_A          = SCREEN_A + $3f8
.const PTR_B          = SCREEN_B + $3f8
.const D018_A         = $14             // VM = $0400, CB = $1000 (char ROM)
.const D018_B         = $a4             // VM = $2800, CB = $1000

// $D011 without the fine scroll: DEN=1, RSEL=0, RST8=0.
// RSEL=0 (24 rows) is deliberate. Scrolling 25 matrix rows through a 24-row
// window hides the 8 pixels of scroll slack in the border. In 25-row mode the
// same slack is displayed as an idle strip, which is exactly the kind of
// meaningless artefact that makes a human distrust a manual acceptance run.
.const D011_BASE      = $10

.const COLOUR_RAM     = $d800
.const SCREEN_ROWS    = 25

// HUD rows. With RSEL=0 rows 1..23 are always fully visible whatever the fine
// scroll is; rows 0 and 24 are the slack and may be clipped.
.const HUD_ROW_STATS  = 1
.const HUD_ROW_SCROLL = 2
.const HUD_ROW_FIX    = 23
.const KEY_COL        = 29

// Indirect indexed addressing REQUIRES a zero-page pointer. $fb/$fc belong to
// loadFixture; $fd/$fe are the other free pair on an unexpanded C64.
.const scrPtr         = $fd

BasicUpstart2(entry)

// Imported first so their constants resolve in KickAssembler's first parse.
// Each module owns its own segment, so import order does not affect layout.
#import "sprites.asm"
#import "renderer.asm"
#import "fixtures.asm"
#import "scroll.asm"

* = $0810 "main"

entry:
    sei
    lda #$0b
    sta $d011                           // screen off while we set up
    lda #$00
    sta $d020
    sta $d021
    sta $d01c                           // all sprites hires
    sta $d017                           // no Y expand
    sta $d01d                           // no X expand
    sta $d01b                           // sprites in front

    jsr initColour

    lda #0
    sta fixtureIndex
    sta keyDown
    sta lastFrameSeen
    lda #1
    sta prevNext                        // Start in the HELD state, so a press
                                        // only counts after a release. VICE's
                                        // autostart drives the keyboard matrix
                                        // to type RUN, and a launch was once
                                        // observed coming up on fixture 3; this
                                        // makes startup deterministic whatever
                                        // the host leaves in the matrix.

    jsr rebuild                         // build + publish fixture 0
    jsr scrollInit                      // build both pages, publish frame 0
    jsr installRenderer                 // renderer owns the IRQ chain from here
    cli

// ---------------------------------------------------------------------------
// The main loop runs once per DISPLAYED frame, paced by the renderer's own
// frame counter. Order matters and is the whole of P1's frame ownership:
//
//   1. hudTick     writes the page that is on screen RIGHT NOW. dispPage still
//                  names it, because scrollTick has not run yet this frame.
//   2. regenTick   rebuilds the BACK page, which nothing is displaying.
//   3. scrollTick  advances the scroll and publishes the record the NEXT frame
//                  IRQ will adopt. Only here can dispPage change.
//
// So no main-thread write ever lands on the page the VIC is fetching, and the
// page decision is made at exactly one point per frame.
// ---------------------------------------------------------------------------
mainLoop:
    jsr readNextFixture
    beq !noKey+

    inc fixtureIndex
    lda fixtureIndex
    cmp #FIXTURE_COUNT
    bcc !ok+
    lda #0
    sta fixtureIndex
!ok:
    jsr rebuild
!noKey:
    lda frameCounter
    cmp lastFrameSeen
    beq mainLoop                        // same displayed frame: nothing to do
    sta lastFrameSeen

    jsr hudTick
    jsr regenTick
    jsr scrollTick
    jmp mainLoop

// ---------------------------------------------------------------------------
// rebuild — load the selected fixture, build the NEXT schedule, publish it.
// This is the entire main-thread contribution to sprite rendering.
// ---------------------------------------------------------------------------
rebuild:
    lda fixtureIndex
    jsr loadFixture
    jsr buildSchedule
    jsr publishSchedule
    rts

// ---------------------------------------------------------------------------
// Fixture-select edge detect: keyboard SPACE, row 7 / bit 4. No KERNAL.
//
// This scan is correct and always was. What broke manual acceptance once was
// the LAUNCH, and it is worth writing down because it is invisible from inside
// the machine: a VICE joystick "keyset" can bind the host SPACE key to an
// emulated joystick (this machine's vicerc had JoyDevice2=2 with
// KeySet1Fire=32, and keysym 32 is SPACE). VICE then consumes the key for the
// joystick and the C64 keyboard matrix never sees it. Measured on the failing
// configuration: every matrix row reads $ff with SPACE held.
//
// The fix is VICE_OPTS in the Makefile, which detaches both joystick devices.
// keyDown makes the remaining failure mode loud rather than silent: the bottom
// bar shows a solid block only while the scan actually sees SPACE down. If it
// never lights, the machine is not receiving the key and the renderer is not
// the suspect.
// ---------------------------------------------------------------------------
readNextFixture:
    lda #$7f
    sta $dc00                           // select keyboard row 7
    lda $dc01
    and #$10
    beq !down+

    lda #0                              // released
    sta keyDown
    sta prevNext
    rts
!down:
    lda #1
    sta keyDown
    lda prevNext
    bne !held+
    lda #1
    sta prevNext
    lda #1                              // fresh press
    rts
!held:
    lda #0
    rts

// ---------------------------------------------------------------------------
// Colour RAM is written ONCE and never again.
//
// There is only one colour RAM and it cannot be double buffered, so anything
// that changed it per coarse step would tear across a page flip with no way to
// publish it atomically. Keeping it fixed removes that problem entirely: the
// characters scroll through a stationary colour field.
// ---------------------------------------------------------------------------
initColour:
    ldx #0
!bg:
    lda #$0f                            // light grey playfield
    sta COLOUR_RAM,x
    sta COLOUR_RAM + $100,x
    sta COLOUR_RAM + $200,x
    sta COLOUR_RAM + $2e8,x
    inx
    bne !bg-

    ldx #0
!hud:
    lda #$01                            // white HUD rows
    sta COLOUR_RAM + (HUD_ROW_STATS * 40),x
    sta COLOUR_RAM + (HUD_ROW_SCROLL * 40),x
    sta COLOUR_RAM + (HUD_ROW_FIX * 40),x
    inx
    cpx #40
    bne !hud-
    rts

// ===========================================================================
// HUD — three fixed screen rows, drawn into whichever page the caller names.
// One code path, used both for the live update on the displayed page and for
// stamping a back page as it is rebuilt.
//
// The HUD sits INSIDE the scrolling matrix, so it rides the fine scroll and
// wobbles by up to 8 pixels. Holding it still needs a mid-screen $d011 write,
// which is a raster split — that is P8, and P1 deliberately does not have one.
// ===========================================================================
hudTick:
    lda dispPage
    bne !pageB+
    lda #>SCREEN_A
    jmp !go+
!pageB:
    lda #>SCREEN_B
!go:
    sta hudPageHi

    ldx #HUD_ROW_STATS
    jsr hudRowAt
    ldx #HUD_ROW_SCROLL
    jsr hudRowAt
    ldx #HUD_ROW_FIX
    jsr hudRowAt
    rts

// X = screen row. Points scrPtr at that row of the hudPageHi page, then draws.
hudRowAt:
    lda rowLo,x
    sta scrPtr
    lda rowHi,x
    clc
    adc hudPageHi
    sta scrPtr + 1
    // fall through

// X = screen row, scrPtr = start of that row. Called from renderRow too.
drawHudRow:
    cpx #HUD_ROW_STATS
    beq drawStatsRow
    cpx #HUD_ROW_SCROLL
    beq drawScrollRow
    jmp drawFixRow

// "FIX nn  ACC nn  REU nn  MRG nn  UNS nn"
drawStatsRow:
    ldy #0
!label:
    lda labelText,y
    beq !values+
    sta (scrPtr),y
    iny
    jmp !label-
!values:
    lda fixtureIndex
    ldy #4
    jsr putHexY
    lda statAccepted
    ldy #12
    jsr putHexY
    lda statReuse
    ldy #20
    jsr putHexY
    lda statRejMargin
    ldy #28
    jsr putHexY
    lda statRejUnsafe
    ldy #36
    jsr putHexY
    rts

// "SCR f  ROW wwww  PG A  CRS cccc" — the scroller stated on screen, so a
// human can read fine phase, world row, displayed page and coarse-step count
// without a monitor.
drawScrollRow:
    ldy #0
!template:
    lda scrollLabelText,y
    sta (scrPtr),y
    iny
    cpy #40
    bne !template-

    lda scrollFine
    clc
    adc #$30
    ldy #4
    sta (scrPtr),y

    lda worldRowHi
    ldy #11
    jsr putHexY
    lda worldRowLo
    ldy #13
    jsr putHexY

    lda dispPage
    clc
    adc #1                              // screen code 1 = 'A', 2 = 'B'
    ldy #20
    sta (scrPtr),y

    lda coarseCount + 1
    ldy #27
    jsr putHexY
    lda coarseCount
    ldy #29
    jsr putHexY
    rts

// "FIXTURE n  SPACE = NEXT   KEY #", reverse video, full width.
drawFixRow:
    ldy #0
!draw:
    lda fixLineText,y
    beq !digit+
    ora #$80                            // reverse video
    sta (scrPtr),y
    iny
    jmp !draw-
!digit:
    lda fixtureIndex
    clc
    adc #$30                            // screen code '0'
    ora #$80
    ldy #8
    sta (scrPtr),y

    lda #$a0                            // pad the bar to full width
    ldy #30
!pad:
    sta (scrPtr),y
    iny
    cpy #40
    bne !pad-

    lda #$a0                            // live key-down block
    ldx keyDown
    bne !lit+
    lda #$20
!lit:
    ldy #KEY_COL
    sta (scrPtr),y
    rts

// A = value, Y = column. Writes two hex digits at (scrPtr),y and y+1.
putHexY:
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hexDigit,x
    sta (scrPtr),y
    iny
    pla
    and #$0f
    tax
    lda hexDigit,x
    sta (scrPtr),y
    rts

hexDigit:  .byte $30,$31,$32,$33,$34,$35,$36,$37,$38,$39,$01,$02,$03,$04,$05,$06

// --- screen-code text -------------------------------------------------------
// Five 8-column fields: label in cols 0..2, value in cols 4..5 of each field,
// so a value can never overwrite a label.
// FIX = fixture, ACC = accepted, REU = reuse events,
// MRG = rejected inside our safety margin, UNS = rejected as physically unsafe.
labelText: .byte   6,  9, 24, 32, 32, 32, 32, 32                    // "FIX     "
           .byte   1,  3,  3, 32, 32, 32, 32, 32                    // "ACC     "
           .byte  18,  5, 21, 32, 32, 32, 32, 32                    // "REU     "
           .byte  13, 18,  7, 32, 32, 32, 32, 32                    // "MRG     "
           .byte  21, 14, 19, 32, 32, 32, 32, 32, 0                 // "UNS     "

// "SCR    ROW       PG    CRS" with gaps for the values, exactly 40 columns.
// value columns: 4 = fine, 11..14 = world row, 20 = page, 27..30 = coarse
scrollLabelText:
           .byte  19,  3, 18, 32, 32, 32, 32                        // "SCR    "  0..6
           .byte  18, 15, 23, 32                                    // "ROW "     7..10
           .byte  32, 32, 32, 32, 32, 32                            //            11..16
           .byte  16,  7, 32                                        // "PG "      17..19
           .byte  32, 32, 32                                        //            20..22
           .byte   3, 18, 19, 32                                    // "CRS "     23..26
           .byte  32, 32, 32, 32                                    //            27..30
           .byte  32, 32, 32, 32, 32, 32, 32, 32, 32                //            31..39

// "FIXTURE n  SPACE = NEXT   KEY" — column 8 is the digit and column KEY_COL
// (29) is the live key-down block, so neither is in this string.
fixLineText: .byte  6,  9, 24, 20, 21, 18,  5, 32                   // "FIXTURE "
             .byte 48                                               // digit slot
             .byte 32, 32, 19, 16,  1,  3,  5, 32, 61, 32, 14,  5, 24, 20  // "  SPACE = NEXT"
             .byte 32, 32, 32, 11,  5, 25, 0                        // "   KEY" (cols 23..28)

fixtureIndex:  .byte 0
prevNext:      .byte 0
keyDown:       .byte 0
lastFrameSeen: .byte 0
