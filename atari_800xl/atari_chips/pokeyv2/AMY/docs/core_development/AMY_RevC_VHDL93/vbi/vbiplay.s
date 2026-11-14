; vbiplay.s: the amybox songs from a VBI, through the PokeyMAX AMY note engine.
;
; The 6502 only runs the score (the JCODE state machine of amybox.c) and posts
; note events; the engine writes every harmonic breakpoint.  Per event:
;   note on:  W0 note, W1 level, W2 harmonics, EVENT $90+v   (4 stores)
;   note off: EVENT $80+v                                    (1 store)
; Each EVENT first checks the queue-full bit; the queue holds 16 events and a
; frame posts at most 8, so the check never waits in practice.
;
; Keys: START next song, SELECT previous.  The screen shows the most VCOUNT
; lines (2 scanlines each) the player has taken in a frame.
;
; The demo runs the player from the main loop at a fixed line on screen, once per
; VBI, with the background in colour while it runs (a raster-time bar); in the VBI
; itself the colour would never show.  Calling play from your own VBI works the same.
;
; Entry points at the start of CODE (the cycle-count harness calls them):
;   +0 start  +3 chip_init  +6 eng_init  +9 start_song (A = song)  +12 play

        .setcpu "6502"
        .export start, nextsong          ; (nextsong: for the cycle-count harness)

AMY     = $D2C0                 ; +0 command/status, 1-3 A/B/C, 4-6 wrapper
EW0     = AMY+8                 ; note engine: word builder
EW1     = AMY+9
EW2     = AMY+10
EEVENT  = AMY+11
EADDR   = AMY+12
EWRITE  = AMY+13
ESTAT   = AMY+14                ; bit 7 busy, bit 6 queue full
ECONF   = AMY+15                ; bit 0 on, bit 1 8 x 8 layout

VCOUNT  = $D40B
PALREG  = $D014
CONSOL  = $D01F
SAVMSC  = $58
SETVBV  = $E45C
XITVBV  = $E462
COLBK   = $D01A                 ; GTIA background colour
COLOR4  = $02C8                 ; its OS shadow
RASTER  = 16                    ; VCOUNT the player runs at (scanline 32: on screen)
RCOLOUR = $36                   ; background while the player runs

WRSOR   = $20                   ; AMY commands
WRSCR   = $30
WRVTYP  = $10
WRHABP  = $40
CLRLHPF = $80
SETLHPF = $81

        .zeropage
sp:     .res 2                  ; stream / upload pointer
dp:     .res 2                  ; duration table of the song
songp:  .res 2                  ; the song
scrp:   .res 2                  ; screen (the main program; the VBI uses sp)
bcode:  .res 1
cnt:    .res 1

        .bss
vpl:    .res 4                  ; per voice: stream pointer
vph:    .res 4
vstate: .res 4                  ; 0 next note, 1 note (or rest), 2 gap, 3 ended
vcnt:   .res 4                  ; units to the next change
vgap:   .res 4
vbase:  .res 4                  ; velocity base
vrest:  .res 4
tempo:  .res 1
treg:   .res 1
tacc:   .res 2                  ; 72.8 Hz score clock, thousandths of a tick
tfrac:  .res 2                  ; per frame, beyond the first tick
playing: .res 1
nended: .res 1                  ; voices that have ended
cursong: .res 1
nextsong: .res 1                ; $FF none, else the song to start
maxl:   .res 1                  ; most VCOUNT lines taken
fdue:   .res 1                  ; set by the VBI: a frame is due
vc0:    .res 1
ntsc:   .res 1
vwrap:  .res 1
waddr:  .res 1

        .code
entry:  jmp start
        jmp chip_init
        jmp eng_init
        jmp start_song
        jmp play

; ---------------------------------------------------------------------------
; the player: once per frame.  The score clock runs 1457 (PAL) or 1214 (NTSC)
; thousandths of a tick per frame: one tick, and a second one when the
; thousandths carry (tfrac = 457 or 214, tacc < 1000).
play:   clc
        lda tacc
        adc tfrac
        sta tacc
        lda tacc+1
        adc tfrac+1
        sta tacc+1
        cmp #>1000              ; tacc >= 1000: two ticks
        bcc tick
        bne :+
        lda tacc
        cmp #<1000
        bcc tick
:       lda tacc                ; C = 1
        sbc #<1000
        sta tacc
        lda tacc+1
        sbc #>1000
        sta tacc+1
        jsr tick
tick:   lda playing
        beq @done
        dec treg
        bne @done
        lda tempo
        sta treg
        jmp unit
@done:  rts

; one score unit for the four voices.  vcnt counts the units to the voice's
; next change, so a voice that is holding a note or a gap costs one DEC.
unit:   ldx #0
@voice: dec vcnt,x
        bne @next
        lda vstate,x
        beq @read
        cmp #2
        beq @gap
        bcs @ended
        lda vrest,x             ; 1: the note (or rest) ends, the gap starts
        bne :+
        jsr note_off
:       lda vgap,x
        sta vcnt,x
        lda #2
        sta vstate,x
@next:  inx
        cpx #4
        bne @voice
        lda nended
        cmp #4
        bne @run
        lda #0                  ; every voice has ended: the next song
        sta playing
        lda cursong
        clc
        adc #1
        cmp #NSONGS
        bcc :+
        lda #0
:       sta nextsong
@run:   rts
@gap:   lda #0                  ; 2: the gap ends, the next note at the next unit
        sta vstate,x
@ended: lda #1                  ; (3: ended, stays so)
        sta vcnt,x
        bne @next

@read:  lda vpl,x               ; 0: the next note
        sta sp
        lda vph,x
        sta sp+1
        ldy #0
@base:  lda (sp),y
        cmp #1
        bne @nb
        iny                     ; 1, v: velocity base
        lda (sp),y
        sta vbase,x
        iny
        bne @base
@nb:    cmp #0
        bne @note
        lda #3                  ; 0: the end of this voice
        sta vstate,x
        lda #1
        sta vcnt,x
        inc nended
        bne @next
@note:  sta bcode
        iny
        lda (sp),y              ; duration number
        iny
        sty cnt
        asl a
        tay
        lda (dp),y
        sta vcnt,x              ; units on (counted from this one)
        iny
        lda (dp),y
        sta vgap,x
        lda bcode
        cmp #2
        beq @rest
        jsr note_on
        lda #0
@rest:  sta vrest,x             ; 2 = rest, 0 = note
        lda #1
        sta vstate,x
        lda cnt                 ; past the note
        clc
        adc sp
        sta vpl,x
        lda #0
        adc sp+1
        sta vph,x
        jmp @voice              ; this unit counts: DEC again

; ---------------------------------------------------------------------------
; events (X = voice, preserved)
; note on: bcode = note code | $80 accent
note_on:
        lda bcode
        and #$7F
        sta EW0                 ; note
        tay
        lda hmtab,y
        sta EW2                 ; harmonics below the band limit
        lda vbase,x             ; level = $B8 + (base + accent) / 4
        clc
        bit bcode
        bpl :+
        adc #16
:       ror a
        lsr a
        clc
        adc #$B8
        sta EW1
:       bit ESTAT               ; queue full?
        bvs :-
        txa
        ora #$90
        sta EEVENT
        rts

note_off:
:       bit ESTAT
        bvs :-
        txa
        ora #$80
        sta EEVENT
        rts

; ---------------------------------------------------------------------------
; A = song: instruments, every voice off, the score from the start
start_song:
        sta cursong
        tay
        lda song_lo,y
        sta songp
        lda song_hi,y
        sta songp+1
        tya                     ; instruments: song_inst + 4 * song
        asl a
        asl a
        tay
        ldx #0
@inst:  lda song_inst,y
        sta EW0
:       bit ESTAT
        bvs :-
        txa
        ora #$A0                ; instrument (also: released long ago)
        sta EEVENT
        jsr note_off
        iny
        inx
        cpx #4
        bne @inst
        ldy #0                  ; tempo, durations
        lda (songp),y
        sta tempo
        lda songp
        clc
        adc #2
        sta dp
        lda songp+1
        adc #0
        sta dp+1
        iny
        lda (songp),y            ; voice offsets after 2 x durations
        asl a
        clc
        adc dp
        sta sp
        lda dp+1
        adc #0
        sta sp+1
        ldx #0
        ldy #0
@voice: lda (sp),y
        clc
        adc songp
        sta vpl,x
        iny
        lda (sp),y
        adc songp+1
        sta vph,x
        iny
        lda #0
        sta vstate,x
        lda #1
        sta vcnt,x
        lda #128
        sta vbase,x
        inx
        cpx #4
        bne @voice
        lda #1
        sta treg
        sta playing
        lda #0
        sta tacc
        sta tacc+1
        sta nended
        lda #$FF
        sta nextsong
        rts

; ---------------------------------------------------------------------------
; the chip: reset, 64 harmonics in 4 voices, silent, sequencer on
wr0:    bit AMY                 ; FIFO full?
        bvs wr0
        sta AMY
        rts

chip_init:
        lda #0
        jsr wr0                 ; reset the chip, drop the queue
:       bit AMY                 ; wait while busy
        bmi :-
        lda #WRSOR | 4          ; 64 harmonics, voices output separately
        jsr wr0
        lda #0
        sta AMY+1
        sta AMY+3
        ldx #0
:       txa
        ora #WRVTYP
        jsr wr0                 ; harmonic voices
        inx
        cpx #8
        bne :-
        ldx #0
:       txa
        ora #WRHABP
        jsr wr0                 ; silence
        inx
        cpx #64
        bne :-
        ldx #0
:       txa
        asl a
        ora #CLRLHPF
        sta cnt
        txa
        and #7
        cmp #7
        bne :+
        inc cnt                 ; SETLHPF: the last pair of each voice
:       lda cnt
        jsr wr0
        inx
        cpx #32
        bne :--
        lda #WRSCR | 1          ; sequencer on
        jsr wr0
        lda #$0D                ; voice 0 left, 1 right, 2 and 3 both
        sta AMY+4
        lda #$0E
        sta AMY+5
        lda #$F0
        sta AMY+6
        rts

; the engine: RAM image, pitch of note 0 (A = 0 PAL, else NTSC), on
eng_init:
        sta ntsc
        lda #1
        sta ECONF               ; on, 16 harmonics x 4 voices
        lda #40                 ; word 40: frequency word of note 0
        sta EADDR
        ldy ntsc
        beq :+
        ldy #2
:       lda freq0_pal,y
        sta EW0
        lda freq0_pal+1,y
        sta EW1
        lda #0
        sta EW2
        sta EWRITE
        lda #<engram
        sta sp
        lda #>engram
        sta sp+1
@run:   ldy #0
        lda (sp),y              ; first word, 0 = end
        beq @done
        sta waddr
        iny
        lda (sp),y
        sta cnt
@word:  lda waddr
        sta EADDR
        inc waddr
        iny
        lda (sp),y
        sta EW0
        iny
        lda (sp),y
        sta EW1
        iny
        lda (sp),y
        sta EW2
        iny
        lda (sp),y
        sta EWRITE              ; RAM word ADDR
        dec cnt
        bne @word
        iny                     ; next run
        tya
        clc
        adc sp
        sta sp
        bcc @run
        inc sp+1
        jmp @run
@done:  lda #<457               ; 72.85 Hz = 1.457 ticks per 50 Hz frame
        ldx #>457
        ldy ntsc
        beq :+
        lda #<214               ; ... 1.214 per 60 Hz frame
        ldx #>214
:       sta tfrac
        stx tfrac+1
        rts

; ---------------------------------------------------------------------------
; the Atari program
start:  ldx #1                  ; PAL: GTIA says 1 in bits 1-3
        lda PALREG
        and #$0E
        bne :+
        dex
:       lda vwrap_t,x           ; VCOUNT wraps after 156 (PAL) or 131
        sta vwrap
        txa                     ; 0 PAL, 1 NTSC
        pha
        jsr chip_init
        pla
        jsr eng_init
        jsr clear
        ldy #0
        ldx #0
        jsr text                ; title
        lda ECONF
        and #1
        bne :+
        ldy #2*40
        ldx #t_none - texts
        jsr text
@halt:  jmp @halt
:       ldy #4*40
        ldx #t_keys - texts
        jsr text
        ldy #5*40
        ldx #t_lines - texts
        jsr text
        lda #0
        sta maxl
        jsr start_song
        jsr show_song
        lda #7                  ; deferred VBI
        ldy #<vbi
        ldx #>vbi
        jsr SETVBV

@loop:  jsr service
        lda maxl                ; lines taken, x 2
        asl a
        ldy #5*40+17
        jsr hex2
        lda CONSOL
        and #3
        cmp #3
        beq @loop
        tax                     ; 2 START: next, 1 SELECT: previous
        lda cursong
        cpx #2
        bne @prev
        clc
        adc #1
        cmp #NSONGS
        bcc @set
        lda #0
        beq @set
@prev:  sec
        sbc #1
        bcs @set
        lda #NSONGS - 1
@set:   sta nextsong
:       jsr service
        lda CONSOL              ; wait for the key to go up
        and #3
        cmp #3
        bne :-
        jmp @loop

vbi:    lda #1                  ; a frame is due
        sta fdue
        jmp XITVBV

; one frame when the VBI has asked for it: at line RASTER, background in colour
service:
        lda fdue
        beq @no
:       lda VCOUNT
        cmp #RASTER
        bne :-
        lda #RCOLOUR
        sta COLBK
        lda VCOUNT
        sta vc0
        lda nextsong
        bmi :+
        jsr start_song
        jsr show_song
:       jsr play
        lda COLOR4
        sta COLBK
        lda VCOUNT
        sec
        sbc vc0
        bcs :+
        adc vwrap
:       cmp maxl
        bcc :+
        sta maxl
:       lda #0
        sta fdue
@no:    rts
vwrap_t: .byte 156, 131

show_song:
        lda cursong             ; name: 20 characters at row 2
        asl a
        asl a
        sta cnt
        asl a
        asl a
        adc cnt                 ; x 20
        tax
        ldy #2*40+2
        lda #20
        sta cnt
:       lda song_name,x
        jsr scr
        inx
        iny
        dec cnt
        bne :-
        lda #0
        sta maxl
        rts

; clear the screen (24 rows)
clear:  lda SAVMSC
        sta scrp
        lda SAVMSC+1
        sta scrp+1
        ldx #3                  ; rows 0..19
        ldy #0
        tya
:       sta (scrp),y
        iny
        bne :-
        inc scrp+1
        dex
        bne :-
        rts

; text X (offset in texts, 0-terminated) at screen offset Y (rows 0..5)
text:   lda texts,x
        beq :+
        jsr scr
        inx
        iny
        bne text
:       rts

; ATASCII A to screen offset Y
scr:    pha
        lda SAVMSC
        sta scrp
        lda SAVMSC+1
        sta scrp+1
        pla
        cmp #$60
        bcs :+
        sec
        sbc #$20
:       sta (scrp),y
        rts

; A as two hex digits at screen offset Y
hex2:   pha
        lsr a
        lsr a
        lsr a
        lsr a
        jsr @dig
        pla
        and #15
        iny
@dig:   tax
        lda digits,x
        jmp scr

digits: .byte "0123456789ABCDEF"
.if .defined(CLK8)
texts:  .byte "  AMY NOTE ENGINE: AMYBOX FROM A VBI CLK8", 0
.elseif .defined(CLK4)
texts:  .byte "  AMY NOTE ENGINE: AMYBOX FROM A VBI 4X", 0
.else
texts:  .byte "  AMY NOTE ENGINE: AMYBOX FROM A VBI", 0
.endif
t_none: .byte "  NO AMY NOTE ENGINE IN THIS POKEYMAX", 0
t_keys: .byte "  START NEXT SONG, SELECT PREVIOUS", 0
t_lines: .byte "  VBI LINES MAX $", 0

.if .defined(CLK8)
        .include "vbidata8.inc"         ; tables for AMY at CLK / 8 = 7.168 MHz (engine UNIT_LOG2 = 15)
.elseif .defined(CLK4)
        .include "vbidata4.inc"         ; ... at 4 x PHI2 (UNIT_LOG2 = 15)
.else
        .include "vbidata.inc"          ; ... at 2 x PHI2 (UNIT_LOG2 = 14)
.endif
