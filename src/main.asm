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
// Row 22, NOT row 3. The P2 fixtures put six leader sprites at Y 60-65, which
// is exactly screen rows 1-4, and sprites are in front of characters: on the
// torture fixture the P2 readout was sitting underneath the very sprites it
// exists to describe. Rows 18-22 are below the lowest sprite any P2 fixture
// places (T6X3 reaches Y 194), so row 22 is readable on every fixture.
.const HUD_ROW_P5     = 20              // P5: orbit and X=255 census
.const HUD_ROW_P3     = 21              // P3: motion and capacity faults
.const HUD_ROW_P2     = 22              // P2: geometry identification
.const HUD_ROW_FIX    = 23
.const HUD_ROW_COUNT  = 6               // rows in hudRowList; hudTick draws one
                                        // per frame, round robin.
                                        //
                                        // FIVE, not six. P4 first gave the
                                        // sorter its own row. Round robin made
                                        // that free per frame -- but every HUD
                                        // row must ALSO be stamped into the back
                                        // page as it regenerates, and that cost
                                        // lands on one frame, which is the frame
                                        // that sets the worst-case preparation
                                        // span. It pushed P3's heaviest fixture
                                        // from ~68% of a frame to ~88% and made
                                        // it skip publications. The sorter's own
                                        // diagnostics moved onto the P3 row
                                        // instead, where there were spare
                                        // columns.
// Column 30: the bottom bar's text now runs to column 29 ("...M=P3 KEY"), so
// the live key-down block sits just past it.
.const FIXLINE_LEN    = 30              // columns of text on the bottom bar
.const KEY_COL        = 30

// Indirect indexed addressing REQUIRES a zero-page pointer. $fb/$fc belong to
// loadFixture; $fd/$fe are the other free pair on an unexpanded C64.
.const scrPtr         = $fd

BasicUpstart2(entry)

// Imported first so their constants resolve in KickAssembler's first parse.
// Each module owns its own segment, so import order does not affect layout.
#import "sprites.asm"
#import "renderer.asm"
#import "motion.asm"
#import "sorter.asm"
#import "p3_fixtures.asm"
#import "p4_fixtures.asm"
#import "fixtures.asm"
#import "p5_tables.asm"
#import "p5_ring.asm"
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

    // P3 added eight fixtures, so reaching the moving ones from a cold start
    // costs sixteen SPACE presses. M jumps straight to the first P3 fixture;
    // SPACE then cycles from there as usual. Row 4 of the keyboard matrix,
    // bit 4 -- the same column as SPACE, a different row.
    jsr readJumpP3
    beq !noJump+
    lda #P3_FIRST_FIXTURE
    sta fixtureIndex
    jsr rebuild
!noJump:

    jsr readJumpP4                      // S: straight to the sorter fixtures
    beq !noJump4+
    lda #P4_FIRST_FIXTURE
    sta fixtureIndex
    jsr rebuild
!noJump4:

    jsr readJumpP5                      // R: straight to the ring fixtures
    beq !noJump5+
    lda #P5_FIRST_FIXTURE
    sta fixtureIndex
    jsr rebuild
!noJump5:

    lda frameCounter
    cmp lastFrameSeen
    beq mainLoop                        // same displayed frame: nothing to do
    sta lastFrameSeen

    jsr hudTick

    // P3. A moving fixture must have its logical positions advanced and a
    // COMPLETE new schedule built and published every frame. The order is the
    // architecture and is not negotiable: move, then build from the moved
    // values, then publish one byte. Nothing mutates a schedule that has been
    // published, and the executor is never told that anything moved.
    //
    // A static fixture skips both, exactly as in P0/P1/P2, which is why the
    // static regression fixtures cost precisely what they always did.
    lda fixtureMoves
    beq !static+
    jsr motionTick
    jsr republish                       // NOT rebuild: see below
!static:

    jsr regenTick
    jsr scrollTick
    jmp mainLoop

// ---------------------------------------------------------------------------
// rebuild — load the selected fixture, build the NEXT schedule, publish it.
// This is the entire main-thread contribution to sprite rendering.
// ---------------------------------------------------------------------------
// rebuild is fixture SELECTION: load the fixture, then build and publish. It
// resets motion state and positions, so it must happen only when the selected
// fixture actually changes.
rebuild:
    lda fixtureIndex
    jsr loadFixture
    jsr republish
    rts

// republish is the per-frame path for a moving fixture: build a complete NEXT
// schedule from whatever the logical arrays currently hold, and publish it.
//
// It deliberately does NOT call loadFixture. The first version of this called
// rebuild every frame, which reloaded the fixture -- resetting every position
// and the motion frame counter -- immediately after motionTick had advanced
// them. Motion therefore never accumulated: the sprites sat still, motionFrame
// read 0 forever, and the per-frame reload cost enough main-thread time to
// start skipping scroll publications. Two separate entry points, so the
// difference between "select this fixture" and "prepare the next frame" cannot
// be blurred again.
republish:
    jsr sortTick                        // P4: order by Y BEFORE admission
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

// Edge-detected M, the same shape as readNextFixture and for the same reason:
// a held key must count once.
readJumpP3:
    lda #$ef                            // keyboard row 4
    sta $dc00
    lda $dc01
    and #$10
    beq !down+
    lda #0
    sta prevJump
    rts
!down:
    lda prevJump
    bne !held+
    lda #1
    sta prevJump
    rts                                 // fresh press: A = 1
!held:
    lda #0
    rts

// Edge-detected R, row 2 of the keyboard matrix, bit 1. Same shape as the
// other two jump keys and for the same reason: a held key must count once.
readJumpP5:
    lda #$fb                            // keyboard row 2
    sta $dc00
    lda $dc01
    and #$02
    beq !down+
    lda #0
    sta prevJump5
    rts
!down:
    lda prevJump5
    bne !held+
    lda #1
    sta prevJump5
    rts                                 // fresh press: A = 1
!held:
    lda #0
    rts

// Edge-detected S, row 1 of the keyboard matrix, bit 5.
readJumpP4:
    lda #$fd                            // keyboard row 1
    sta $dc00
    lda $dc01
    and #$20
    beq !down+
    lda #0
    sta prevJump4
    rts
!down:
    lda prevJump4
    bne !held+
    lda #1
    sta prevJump4
    rts                                 // fresh press: A = 1
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
    sta COLOUR_RAM + (HUD_ROW_P5 * 40),x
    sta COLOUR_RAM + (HUD_ROW_P3 * 40),x
    sta COLOUR_RAM + (HUD_ROW_P2 * 40),x
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
// ONE row per frame, round robin, not all five.
//
// P3 measured this. Drawing all five diagnostic rows every frame cost enough
// main-thread time that the integrated moving fixture's per-frame preparation
// reached 74.6% of a PAL frame, and passes began straddling the frame
// boundary: publishFrame then found the previous record still unadopted and
// counted a publication skip, which a human sees as a one-frame scroll
// stutter. 70 skips in 20,000 frames -- rare, real, and entirely avoidable.
//
// The HUD is a diagnostic surface, not gameplay. Every row still updates ten
// times a second, which is faster than a human reads, and the cost drops to a
// fifth. Nothing else about the frame changes: the row content, the page it is
// written to, and the stamping of HUD rows into a regenerating back page are
// all exactly as before.
hudTick:
    lda dispPage
    bne !pageB+
    lda #>SCREEN_A
    jmp !go+
!pageB:
    lda #>SCREEN_B
!go:
    sta hudPageHi

    ldx hudCursor
    lda hudRowList,x
    tax
    jsr hudRowAt

    inc hudCursor
    lda hudCursor
    cmp #HUD_ROW_COUNT
    bcc !wrapped+
    lda #0
    sta hudCursor
!wrapped:
    rts

hudRowList:  .byte HUD_ROW_STATS, HUD_ROW_SCROLL, HUD_ROW_P5, HUD_ROW_P3
             .byte HUD_ROW_P2, HUD_ROW_FIX
hudCursor:   .byte 0

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
// Five HUD rows now, and the row bodies between them are long, so every arm
// of this dispatch is an absolute jump rather than a relative branch. Written
// once in this shape instead of discovering the range limit one row at a time.
drawHudRow:
    cpx #HUD_ROW_STATS
    bne !notStats+
    jmp drawStatsRow
!notStats:
    cpx #HUD_ROW_SCROLL
    bne !notScroll+
    jmp drawScrollRow
!notScroll:
    cpx #HUD_ROW_P5
    bne !notP5+
    jmp drawP5Row
!notP5:
    cpx #HUD_ROW_P3
    bne !notP3+
    jmp drawP3Row
!notP3:
    cpx #HUD_ROW_P2
    bne !notP2+
    jmp drawP2Row
!notP2:
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

// "MOV n  MFRM nnnn  OVF nn  SRT nn  FLT nn" — what P3 and P4 added, on ONE
// row, and nothing that is already on another.
//
// MOV  1 when this fixture has trajectories, so the main loop is re-running
//      motion and rebuilding the whole schedule every frame. 0 is a static
//      P0/P1/P2 fixture, untouched between fixture changes.
// MFRM frames of MOTION, which is what a trajectory is indexed by. On a moving
//      fixture it must advance continuously; if it stops while the playfield
//      keeps scrolling, the main thread has stopped preparing frames.
// OVF  logical sprites that did not fit MAX_SCHED. Must read 00 on every
//      fixture except MAXCAP, which exists to make it read 06.
// SRT  sorted count -- how many logical IDs the sorter handed the builder.
//      Must equal LOG on row 22: P4 has no visibility filtering, so every
//      logical sprite is offered.
// FLT  sorter fault, saturating. Must ALWAYS read 00.
//
// BOV (batch overflow) was dropped from the display to make room. It is
// structurally unreachable while MAX_SCHED is 24 -- batch 0 holds six, so at
// most nineteen batches can exist -- and every suite asserts it is zero. The
// sorter's shift counter sortWork is likewise a timing diagnostic the tests
// read directly rather than something a human watches.
// "RING ORB nnnn  UP nnnn  DN nnnn  FEL nn" — the P5 orbit census.
//
// ORB counts completed orbits: the phase accumulator's high byte wrapping
// through zero. On a ring fixture it must climb steadily; if it stops while the
// scroller keeps moving, motion has died and everything below it is measuring
// a still picture.
//
// UP and DN count logical X crossings of 255 in each direction, counted by the
// ENGINE rather than predicted by the model. They must both climb, and on a
// closed orbit they must stay within one of each other -- every sprite that
// goes out must come back. A model can believe X crossed 255; this is the
// machine saying it did.
//
// FEL is frameEntryLine, and it is the one number on this screen that must
// never change. The frame transaction is armed for raster 250 and must execute
// there; $FA is correct and anything else means the handler was re-entered
// mid-display, which is the FIX 16 fault. A human can watch this single field
// and know the invariant still holds.
drawP5Row:
    ldy #0
!template:
    lda p5LabelText,y
    sta (scrPtr),y
    iny
    cpy #40
    bne !template-

    lda ringOrbits + 1
    ldy #9
    jsr putHexY
    lda ringOrbits
    ldy #11
    jsr putHexY

    lda ringX255Up + 1
    ldy #18
    jsr putHexY
    lda ringX255Up
    ldy #20
    jsr putHexY

    lda ringX255Down + 1
    ldy #27
    jsr putHexY
    lda ringX255Down
    ldy #29
    jsr putHexY

    lda frameEntryLine
    ldy #37
    jsr putHexY
    rts

drawP3Row:
    ldy #0
!template:
    lda p3LabelText,y
    sta (scrPtr),y
    iny
    cpy #40
    bne !template-

    lda fixtureMoves
    clc
    adc #$30
    ldy #4
    sta (scrPtr),y

    lda motionFrame + 1
    ldy #11
    jsr putHexY
    lda motionFrame
    ldy #13
    jsr putHexY

    lda statOverflow
    ldy #20
    jsr putHexY
    lda sortedCount
    ldy #27
    jsr putHexY
    lda sortFault
    ldy #34
    jsr putHexY
    rts

// "LOG nn  MXB nn  OFF nn  B6 nnnn  PH n  PG A" — the P2 geometry on screen.
//
// LOG is the logical sprite count the fixture offered, against ACC on row 1:
// the difference is what was rejected, and a human can see at a glance that a
// fixture showing fewer sprites than it lists is doing that BY DESIGN.
// MXB is the widest MID-SCREEN batch in the schedule -- 6 on the torture
// fixture, and the whole point of P2.
// OFF is the vertical sweep offset added to every Y.
// B6 counts six-entry mid-screen batches the EXECUTOR actually ran, low 16
// bits. On fixture 5 it must climb continuously; if it ever stops while the
// scroller keeps moving, the merged batch is not executing and the run is a
// failure whatever the other counters say.
drawP2Row:
    ldy #0
!template:
    lda p2LabelText,y
    sta (scrPtr),y
    iny
    cpy #40
    bne !template-

    lda logCount
    ldy #4
    jsr putHexY
    lda statMaxBatch
    ldy #12
    jsr putHexY
    lda fixtureYOffset
    ldy #20
    jsr putHexY
    lda batchSizeHist + 13              // six-entry bucket, high byte
    ldy #27
    jsr putHexY
    lda batchSizeHist + 12              // ...and low byte
    ldy #29
    jsr putHexY

    // Fine phase and displayed page are repeated here because row 2, which
    // also carries them, is covered by the leader cluster on every P2 fixture.
    lda scrollFine
    clc
    adc #$30
    ldy #34
    sta (scrPtr),y
    lda dispPage
    clc
    adc #1                              // screen code 1 = 'A', 2 = 'B'
    ldy #38
    sta (scrPtr),y
    rts

// "FIXTURE n  SPACE = NEXT   KEY #", reverse video, full width.
// BOUNDED BY A LENGTH, NOT BY A TERMINATOR.
//
// This loop used to run until it read a zero byte from fixLineText. P4 rewrote
// the bottom bar's text ("M=P3 KEY" became "M=3 S=4") and the terminating zero
// went with it -- so the loop ran off the end of the table and kept storing,
// with Y climbing past 39.
//
// Row 23 starts at $07B8. Y = $40 is $07F8, which is the SPRITE POINTER TABLE
// of the page currently on screen. The HUD was therefore overwriting the live
// sprite pointers with reverse-video label bytes roughly once every five frames
// -- the round-robin period -- and the VIC then fetched sprite bitmaps from
// whatever address those bytes named. That is the flicker and the "corruption"
// a human saw on FIX 19/1A/1C, and it is why reused sprites looked healthier:
// a mid-screen batch rewrites its slots' pointers later in the same frame and
// repairs them before the fetch, while batch-0-only sprites are never repaired.
//
// A length cannot go missing the way a terminator can, and the assembler now
// checks it against the table.
drawFixRow:
    ldy #0
!draw:
    lda fixLineText,y
    ora #$80                            // reverse video
    sta (scrPtr),y
    iny
    cpy #FIXLINE_LEN
    bne !draw-
!digit:
    lda fixtureIndex                    // two hex digits: 24 fixtures now
    lsr
    lsr
    lsr
    lsr
    tax
    lda hexDigit,x
    ora #$80
    ldy #8
    sta (scrPtr),y
    lda fixtureIndex
    and #$0f
    tax
    lda hexDigit,x
    ora #$80
    ldy #9
    sta (scrPtr),y

    lda #$a0                            // pad the bar to full width
    ldy #31
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
// "FIXTURE nn  SPACE=NEXT  M=P3  KEY #". Two digits now: there are 24 fixtures.
p5LabelText:
             .byte 18,  9, 14,  7, 32, 15, 18,  2, 32, 48, 48, 48, 48        // 'RING ORB 0000'
             .byte 32, 32, 21, 16, 32, 48, 48, 48, 48, 32, 32,  4, 14        // '  UP 0000  DN'
             .byte 32, 48, 48, 48, 48, 32, 32,  6,  5, 12, 32, 48, 48        // ' 0000  FEL 00'
             .byte 32        // ' '

// P5 added a third jump key and the bar is capped at KEY_COL characters, so
// "SPACE=NEXT" became "SPC=NXT" to pay for "R=5". The hex fixture digits stay
// at columns 8 and 9, where drawFixRow writes them.
fixLineText: .byte  6,  9, 24, 20, 21, 18,  5, 32                   // "FIXTURE "  0..7
             .byte 48, 48, 32                                       // digits 8,9 + space
             .byte 19, 16,  3, 61, 14, 24, 20, 32                   // "SPC=NXT "   11..18
             .byte 13, 61, 51, 32                                   // "M=3 "       19..22
             .byte 19, 61, 52, 32                                   // "S=4 "       23..26
             .byte 18, 61, 53                                       // "R=5"        27..29
fixLineTextEnd:

// The loop that draws this row is bounded by FIXLINE_LEN, and the two must
// agree or the row either stops short or -- as it did -- runs past the end of
// the screen row and into the sprite pointer table. Checked here so editing the
// text can never silently reintroduce that.
.if (fixLineTextEnd - fixLineText != FIXLINE_LEN) {
    .error "fixLineText length does not match FIXLINE_LEN"
}
.if (FIXLINE_LEN > KEY_COL) {
    .error "fixLineText would overwrite the key-down block"
}

// "LOG    MXB    OFF    B6      PH  PG" with gaps for the values, exactly 40
// columns. Value columns: 4..5 = logical count, 12..13 = max mid-screen batch,
// 20..21 = Y offset, 27..30 = six-entry batches executed, 34 = fine phase,
// 38 = displayed page.
// "MOV    MFRM      OVF    SRT    FLT" with gaps for the values, exactly 40
// columns. Value columns: 4 = moving flag, 11..14 = motion frame,
// 20..21 = schedule overflow, 27..28 = sorted count, 34..35 = sorter fault.
p3LabelText:
           .byte  13, 15, 22, 32, 32, 32                        // "MOV   "   0..5
           .byte  13,  6, 18, 13, 32, 32, 32, 32, 32, 32        // "MFRM      " 6..15
           .byte  15, 22,  6, 32, 32, 32, 32                    // "OVF    "  16..22
           .byte  19, 18, 20, 32, 32, 32, 32                    // "SRT    "  23..29
           .byte   6, 12, 20, 32, 32, 32, 32                    // "FLT    "  30..36
           .byte  32, 32, 32                                    //            37..39

p2LabelText:
           .byte  12, 15,  7, 32, 32, 32, 32, 32                // "LOG    "  0..7
           .byte  13, 24,  2, 32, 32, 32, 32, 32                // "MXB    "  8..15
           .byte  15,  6,  6, 32, 32, 32, 32, 32                // "OFF    "  16..23
           .byte   2, 54, 32, 32, 32, 32, 32, 32                // "B6     "  24..31
           .byte  16,  8, 32, 32                                // "PH  "     32..35
           .byte  16,  7, 32, 32                                // "PG  "     36..39

fixtureIndex:  .byte 0
prevNext:      .byte 0
prevJump5:     .byte 1                  // as prevJump
prevJump4:     .byte 1                  // as prevJump
prevJump:      .byte 1                  // start HELD, like prevNext: a press
                                        // only counts after a release, so
                                        // whatever autostart leaves in the
                                        // matrix cannot select a fixture
keyDown:       .byte 0
lastFrameSeen: .byte 0
