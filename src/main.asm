// ===========================================================================
// 6502-engine — P0: static screen + static pre-sorted sprites
// ===========================================================================
// PAL Commodore 64. 19,656 cycles per frame. Legal NMOS 6502/6510 only.
// KickAssembler 5.25.
//
// P0 proves ONE thing:
//   a prepared logical sprite set is displayed deterministically through the
//   six intended hardware mux slots (2..7), from a complete immutable schedule
//   consumed by a small raster executor, with no visible corruption and no
//   hidden gameplay dependency.
//
// No scrolling. No HUD. No player. No AI. No collision. No sorting.
//
// Controls: SPACE cycles the fixture. VICE must be launched with the joystick
// devices detached or a keyset will swallow the key -- see readNextFixture and
// VICE_OPTS in the Makefile. The fixture index is also pokeable at
// `fixtureIndex` so automated tests can select one without keyboard input.
// ===========================================================================

.const SPRITE_PTR_BASE = $07f8          // P0 has ONE screen page, so exactly one
                                        // pointer destination. P1 introduces the
                                        // second page and must make the choice of
                                        // destination explicit, not write both.
.const SCREEN          = $0400
.const KEY_COL         = 29             // bottom-bar column of the key-down block
.const COLOUR_RAM      = $d800

BasicUpstart2(entry)

// Imported first so their constants resolve in KickAssembler's first parse.
// Each module owns its own segment, so import order does not affect layout.
#import "sprites.asm"
#import "renderer.asm"
#import "fixtures.asm"

* = $0810 "main"

entry:
    sei
    lda #$0b
    sta $d011                           // screen off while we set up
    jsr initScreen

    lda #$00
    sta $d020
    sta $d021
    lda #$00
    sta $d01c                           // all sprites hires
    sta $d017                           // no Y expand
    sta $d01d                           // no X expand
    sta $d01b                           // sprites in front

    lda #0
    sta fixtureIndex
    lda #1
    sta prevNext                        // Start in the HELD state, so a press
                                        // only counts after a release. VICE's
                                        // autostart drives the keyboard matrix
                                        // to type RUN, and a launch was once
                                        // observed coming up on fixture 3; this
                                        // makes startup deterministic whatever
                                        // the host leaves in the matrix.

    jsr rebuild                         // build + publish fixture 0

    lda #$1b
    sta $d011                           // screen on
    jsr installRenderer                 // renderer owns the IRQ chain from here
    cli

mainLoop:
    jsr readNextFixture
    beq mainLoop                        // no new press

    inc fixtureIndex
    lda fixtureIndex
    cmp #FIXTURE_COUNT
    bcc !ok+
    lda #0
    sta fixtureIndex
!ok:
    jsr rebuild
    jmp mainLoop

// ---------------------------------------------------------------------------
// rebuild — load the selected fixture, build the NEXT schedule, publish it.
// This is the entire main-thread contribution to rendering.
// ---------------------------------------------------------------------------
rebuild:
    lda fixtureIndex
    jsr loadFixture
    jsr buildSchedule
    jsr publishSchedule
    jsr showStats
    rts

// ---------------------------------------------------------------------------
// Fixture-select edge detect: keyboard SPACE, row 7 / bit 4. No KERNAL.
//
// This scan is correct and always was. What broke manual acceptance was the
// LAUNCH, and it is worth writing down because it is invisible from inside the
// machine: a VICE joystick "keyset" can bind the host SPACE key to an emulated
// joystick (this machine's vicerc had JoyDevice2=2 with KeySet1Fire=32, and
// keysym 32 is SPACE). VICE then consumes the key for the joystick and the C64
// keyboard matrix never sees it. Measured on the failing configuration: every
// matrix row reads $ff with SPACE held, and the fixture never changes.
//
// Reading joystick port 2 as a second input source was tried and REJECTED: on
// the failing configuration the fire line is not asserted either — the key is
// simply swallowed — so it fixed nothing and could not be verified in any
// configuration. The real fix is VICE_OPTS in the Makefile, which detaches both
// joystick devices so nothing can intercept a host key. `.vscode/tasks.json`
// now shells out to the Makefile so that launch cannot drift again.
//
// keyDownChar makes the remaining failure mode loud rather than silent: the
// bottom bar shows a solid block only while the scan actually sees SPACE down.
// If it never lights, the machine is not receiving the key and the renderer is
// not the suspect.
// ---------------------------------------------------------------------------
readNextFixture:
    lda #$7f
    sta $dc00                           // select keyboard row 7
    lda $dc01
    and #$10
    beq !down+

    lda #$20                            // released: blank the key indicator
    sta SCREEN + (24 * 40) + KEY_COL
    lda #0
    sta prevNext
    rts
!down:
    lda #$a0                            // reverse space: a solid block
    sta SCREEN + (24 * 40) + KEY_COL
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
// Diagnostics: fixture index and the four schedule counters, on screen.
// ---------------------------------------------------------------------------
initScreen:
    ldx #0
!clr:
    lda #$20
    sta SCREEN,x
    sta SCREEN + $100,x
    sta SCREEN + $200,x
    sta SCREEN + $2e8,x
    lda #$01
    sta COLOUR_RAM,x
    sta COLOUR_RAM + $100,x
    sta COLOUR_RAM + $200,x
    sta COLOUR_RAM + $2e8,x
    inx
    bne !clr-

    ldx #0
!t1:
    lda titleText,x
    beq !t2+
    sta SCREEN,x
    inx
    jmp !t1-
!t2:
    ldx #0
!t3:
    lda labelText,x
    beq !t4+
    sta SCREEN + 40,x
    inx
    jmp !t3-
!t4:
    ldx #0
!t5:
    lda helpText,x
    beq !t6+
    sta SCREEN + 80,x
    inx
    jmp !t5-
!t6:
    rts

showStats:
    // Labels start at columns 0/8/16/24/32; values sit in the gap after each,
    // so a value can never overwrite a label.
    lda fixtureIndex
    ldx #(40 + 4)
    jsr putHex
    lda statAccepted
    ldx #(40 + 12)
    jsr putHex
    lda statReuse
    ldx #(40 + 20)
    jsr putHex
    lda statRejMargin
    ldx #(40 + 28)
    jsr putHex
    lda statRejUnsafe
    ldx #(40 + 36)
    jsr putHex
    // fall through: the big, unmissable indicator

// ---------------------------------------------------------------------------
// showFixtureLine — the active fixture, stated plainly.
//
// `FIX nn` in the status line is easy to miss, and rows 0..2 sit UNDER the
// sprite cascade ($d01b = 0, sprites in front), so the one number an operator
// needs during a long dwell can be covered by a box. Row 24 starts at raster
// ~242, below the lowest sprite any fixture places (Y 217 + 21 = 238), so this
// bar is never obscured. Reverse video so it reads as a solid block.
// ---------------------------------------------------------------------------
showFixtureLine:
    ldx #0
!draw:
    lda fixLineText,x
    beq !digit+
    ora #$80                            // reverse video
    sta SCREEN + (24 * 40),x
    inx
    jmp !draw-
!digit:
    lda fixtureIndex
    clc
    adc #$30                            // screen code '0'
    ora #$80
    sta SCREEN + (24 * 40) + 8
    rts

// A = value, X = screen offset. Writes two hex digits.
putHex:
    pha
    lsr
    lsr
    lsr
    lsr
    tay
    lda hexDigit,y
    sta SCREEN,x
    inx
    pla
    and #$0f
    tay
    lda hexDigit,y
    sta SCREEN,x
    rts

hexDigit:  .byte $30,$31,$32,$33,$34,$35,$36,$37,$38,$39,$01,$02,$03,$04,$05,$06

// screen codes
titleText: .byte  16,  0, 13, 21, 24, 32, 16, 18, 15, 15, 6, 32, 32
           .byte  19, 12, 15, 20, 19, 32, 50, 45, 55, 0
// Five 8-column fields: label in cols 0..2, value in cols 4..5 of each field.
// FIX = fixture, ACC = accepted, REU = reuse events,
// MRG = rejected inside our safety margin, UNS = rejected as physically unsafe.
labelText: .byte   6,  9, 24, 32, 32, 32, 32, 32                    // "FIX     "
           .byte   1,  3,  3, 32, 32, 32, 32, 32                    // "ACC     "
           .byte  18,  5, 21, 32, 32, 32, 32, 32                    // "REU     "
           .byte  13, 18,  7, 32, 32, 32, 32, 32                    // "MRG     "
           .byte  21, 14, 19, 32, 32, 32, 32, 32, 0                 // "UNS     "
helpText:  .byte  19, 16,  1,  3,  5, 32, 61, 32, 14,  5, 24, 20
           .byte  32,  6,  9, 24, 20, 21, 18,  5, 0                 // "SPACE = NEXT FIXTURE"
// "FIXTURE n  SPACE = NEXT". Column 8 holds the digit and is patched per build.
// "FIXTURE n  SPACE = NEXT   KEY " — column KEY_COL (29) is the live key-down
// block, written by readNextFixture, so it is deliberately NOT in this string.
fixLineText: .byte  6,  9, 24, 20, 21, 18,  5, 32                   // "FIXTURE "
             .byte 48                                               // digit slot
             .byte 32, 32, 19, 16,  1,  3,  5, 32, 61, 32, 14,  5, 24, 20  // "  SPACE = NEXT"
             .byte 32, 32, 32, 11,  5, 25, 0                        // "   KEY" (cols 23..28)

fixtureIndex: .byte 0
prevNext:     .byte 0
