; amyconv.s: AMY arrangements of POKEY classics, played from a VBI through the PokeyMAX AMY
; note engine (8 voices x 8 harmonics, INDIVIDUAL mode, AMY Rev. C at 8.192 MHz).
;
; Per frame the VBI first writes the vibrato (frequency jumps, straight to the chip while the
; engine is idle), then reads the tune's stream until a wait and posts its events:
;   $00-$3F wait n+1 frames         $40+v note off v
;   $48+v   note on v: note, level  $50+v vibrato depth for voice v
;   $58+v   instrument v: inst      $60 lo hi n: play n bytes from lo/hi, then carry on
;   $61     end: from the start   $68+v note on v keeping the harmonics (W2)
; On NTSC the player skips every sixth VBI so the tunes keep their PAL tempo.
;
; Keys: START next tune, SELECT previous, OPTION Rev C features on/off.  The screen shows the
; most VCOUNT lines (2 scanlines each) a VBI has taken, and goes white while the player runs.
;
; Rev C features (on at start): the extensions are unlocked, so each instrument select also
; sends the instrument's voice type (white noise for the hat and snare), trim, pitch envelope
; (the kick's exponential drop) and per-harmonic detune and diffusion from the engine's
; extension page.  Off: locked, the original noise types, exactly the Rev B sound.
;
; Entry points at the start of CODE (the cycle-count harness calls them):
;   +0 start  +3 chip_init  +6 eng_init  +9 start_tune (A = tune)  +12 play

        .setcpu "6502"
        .export start, nexttune

AMY     = $D2C0                 ; +0 command/status, 1-3 A/B/C, 4-6 wrapper, 8-15 engine
EW0     = AMY+8
EW1     = AMY+9
EW2     = AMY+10
EEVENT  = AMY+11
EADDR   = AMY+12
EWRITE  = AMY+13
ESTAT   = AMY+14                ; bit 7 busy, bit 6 queue full
ECONF   = AMY+15

VCOUNT  = $D40B
PALREG  = $D014
CONSOL  = $D01F
SAVMSC  = $58
SETVBV  = $E45C
XITVBV  = $E462
COLBK   = $D01A                 ; GTIA border / background colour
COLPF2  = $D018                 ; text background
COLOR4  = $02C8                 ; their OS shadows
COLOR2  = $02C6
RASTER  = 16                    ; VCOUNT the player runs at (scanline 32: on screen)
RCOLOUR = $0E                   ; white while the player runs

WRSOR   = $20
WRSCR   = $30
WRVTYP  = $10
WRHABP  = $40
WRFFBP  = $08
CLRLHPF = $80
WRNOISE = $80                   ; + address, while NZINIT is set: Noise RAM (A bits 2-0)

LEFT    = $CB                   ; voices 0 1 3 6 7 left, 0 2 4 5 6 right
RIGHT   = $75

        .zeropage
sp:     .res 2                  ; stream pointer
rp:     .res 2                  ; return pointer while in a $60 reference
scrp:   .res 2                  ; screen (main program)
up:     .res 2                  ; upload pointer
cnt:    .res 1

        .bss
inref:  .res 1                  ; bytes left in the reference, 0 = not in one
wait:   .res 1                  ; frames to wait
vnote:  .res 8                  ; per voice: note, $FF = none
vdepth: .res 8                  ; per voice: vibrato depth
phase:  .res 1                  ; vibrato phase 0..7
tune:   .res 1
nexttune: .res 1                ; $FF none, else the tune to start
ntsc:   .res 1
skip:   .res 1                  ; NTSC: VBIs to the next skipped one
maxl:   .res 1
fdue:   .res 1                  ; set by the VBI: a frame is due
vc0:    .res 1
vwrap:  .res 1
waddr:  .res 1
tmp:    .res 1
looping: .res 1                 ; 1 from the stream's end to its first wait: skip instrument events
off:    .res 1
vinst:  .res 8                  ; per voice: its instrument (for re-selecting)
revc:   .res 1                  ; Rev C features on
reqx:   .res 1                  ; set by OPTION: apply revc at the next frame

        .code
entry:  jmp start
        jmp chip_init
        jmp eng_init
        jmp start_tune
        jmp play

; ---------------------------------------------------------------------------
; once per frame
play:   jsr vibrato
        lda wait
        beq @read
        dec wait
        rts
@read:  jsr getb
        cmp #$40
        bcs @ev
        sta wait                ; wait n+1 frames: this one and n more
        lda #0                  ; past the stream's first frame: instrument events (a voice
        sta looping             ; selected again before a note) are posted again
        rts
@ev:    cmp #$48
        bcs @on
        and #7                  ; $40+v: off
        tax
        lda #$FF
        sta vnote,x
        txa
        ora #$80
        jsr post
        jmp @next
@on:    cmp #$50
        bcs @vib
        and #7                  ; $48+v: on, note, level
        tax
        jsr getb
        sta EW0
        sta vnote,x
        tay
        lda hmtab,y
        sta EW2
        jsr getb
        sta EW1
        txa
        ora #$90
        jsr post
        jmp @next
@vib:   cmp #$58
        bcs @inst
        and #7                  ; $50+v: vibrato depth
        tax
        jsr getb
        sta vdepth,x
        jmp @next
@inst:  cmp #$60
        bcs @ref
        and #7                  ; $58+v: instrument (not in the first frame when looping:
        tax                     ; the voices are not silent, and already have it)
        jsr getb
        sta vinst,x
        ldy looping
        bne @next
        sta EW0
        txa
        ora #$A0
        jsr post
        jmp @next
@ref:   cmp #$62
        bcs @onk
        cmp #$60
        bne @end
        jsr getb                ; $60 lo hi n
        pha
        jsr getb
        pha
        jsr getb
        sta inref
        lda sp
        sta rp
        lda sp+1
        sta rp+1
        pla
        sta sp+1
        pla
        sta sp
        jmp @read
@end:   jsr restart             ; $61: from the start, the voices carrying on
        lda #1
        sta looping
        jmp @read
@onk:   and #7                  ; $68+v: on, note, level; W2 as it is
        tax
        jsr getb
        sta EW0
        sta vnote,x
        jsr getb
        sta EW1
        txa
        ora #$90
        jsr post
        jmp @read
@next:  jmp @read                ; (getb leaves a reference after its last byte)

; the next stream byte (in a reference: counts it, and returns from it after the last)
getb:   ldy #0
        lda (sp),y
        inc sp
        bne :+
        inc sp+1
:       ldy inref
        beq @out
        dey
        sty inref
        bne @out
        pha                     ; the reference's last byte: back to the stream
        lda rp
        sta sp
        lda rp+1
        sta sp+1
        pla
@out:   rts

; post event A (byte 3; W0-W2 are set): wait while the queue is full
post:   bit ESTAT
        bvs post
        sta EEVENT
        rts

; vibrato: voices with a depth and a note get the note's pitch + lfo, as a jump, straight
; to the chip.  Only while the engine is idle (it always is by the next VBI), so the FIFO is
; ours: C, B, A, command at least 5 cycles apart drain faster than they come at 8.192 MHz.
vibrato:
        lda phase               ; the lfo changes on odd frames
        lsr a
        bcc @done
        bit ESTAT
        bmi @done
        lda phase
        asl a
        asl a
        asl a
        asl a
        asl a
        sta tmp                 ; phase * 32
        ldx #0
@v:     lda vdepth,x
        beq @n
        ldy vnote,x
        bmi @n
        ora tmp
        tay
        lda lfo,y               ; signed offset
        sta off
        ldy vnote,x
        lda off
        clc
        bmi @neg
        adc ftab_lo,y
        sta AMY+3               ; C
        lda ftab_hi,y
        adc #0
        jmp @hi
@neg:   adc ftab_lo,y
        sta AMY+3
        lda ftab_hi,y
        adc #$FF
@hi:    and #$1F
        sta AMY+2               ; B
        lda #0
        sta AMY+1               ; A: a jump
        txa
        ora #WRFFBP
        sta AMY                 ; frequency breakpoint
@n:     inx
        cpx #8
        bne @v
@done:  inc phase
        lda phase
        and #7
        sta phase
        rts

; chip register writes, waiting while the FIFO is full
wrA:
:       bit AMY
        bvs :-
        sta AMY+1
        rts
wrA0:   pha
        lda #0
:       bit AMY
        bvs :-
        sta AMY+1
        pla
        rts
wrB:
:       bit AMY
        bvs :-
        sta AMY+2
        rts
wrC:
:       bit AMY
        bvs :-
        sta AMY+3
        rts
wr0:
:       bit AMY
        bvs :-
        sta AMY
        rts

; ---------------------------------------------------------------------------
; A = tune: every voice off, the stream from the start
; A new tune starts from silence: once the engine is idle, every harmonic jumps to 0
; straight away (the old tune's release tails would otherwise overlap the new one, and its
; instrument events tell the engine the voices are silent), then two quiet frames so the
; jumps are applied before the engine writes again.
start_tune:
        sta tune
:       bit ESTAT               ; engine idle?
        bmi :-
        ldx #0
@cut:   lda #0
:       bit AMY
        bvs :-
        sta AMY+1               ; A = 0: a jump
:       bit AMY
        bvs :-
        sta AMY+2               ; B = 0 (an engine breakpoint may have left bit 7 set)
:       bit AMY
        bvs :-
        sta AMY+3               ; C = 0
        txa
        ora #WRHABP
:       bit AMY
        bvs :-
        sta AMY                 ; harmonic x
        inx
        cpx #64
        bne @cut
        ldx #7
@v:     lda #$FF
        sta vnote,x
        lda #0
        sta vdepth,x
        dex
        bpl @v
        lda #6                  ; the stream's first frame gets phase 0
        sta phase
        lda #0
        sta looping
        jsr restart
        lda #2                  ; two quiet frames
        sta wait
        rts
; the stream from the start (also at its end, $61: then the voices carry on, so the
; instrument events are skipped)
restart:
        ldy tune
        lda tune_lo,y
        sta sp
        lda tune_hi,y
        sta sp+1
        lda #0
        sta inref
        sta wait
        lda #$FF
        sta nexttune
        rts

; ---------------------------------------------------------------------------
; the chip: reset, 8 voices of 8 harmonics, voices output separately, silent, running
chip_init:
        lda #0
        jsr wr0                 ; reset the chip, drop the queue
:       bit AMY                 ; wait while busy
        bmi :-
        lda #WRSOR | 4          ; 64 harmonics, INDIVIDUAL
        jsr wr0
        lda #0
        sta AMY+3
        ldx #0
:       lda vtypes,x            ; voice types: the drum voices are noise voices
        sta AMY+1
        txa
        ora #WRVTYP
        jsr wr0
        inx
        cpx #8
        bne :-
        lda #0
        sta AMY+1
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
        and #3
        cmp #3
        bne :+
        inc cnt                 ; set: the last pair of each 8
:       lda cnt
        jsr wr0
        inx
        cpx #32
        bne :--
        lda #WRSCR | 3          ; Noise RAM loading (NZINIT): $80+ writes go to it now,
        jsr wr0                 ; not to the LHP flags, so after those
        ldx #0
:       bit AMY
        bvs :-
        lda noiseram,x
        sta AMY+1
        txa
        ora #WRNOISE
        jsr wr0
        inx
        cpx #64
        bne :-
        lda #WRSCR | 1          ; sequencer on, noise generators running
        jsr wr0
        lda #LEFT
        sta AMY+4
        lda #RIGHT
        sta AMY+5
        lda #$F0
        sta AMY+6
        rts

; the engine: on, 8 x 8, the RAM image (the frequency of note 0 is in it; the
; 8.192 MHz AMY clock is the same in PAL and NTSC)
eng_init:
        lda #3
        sta ECONF
        lda #<engram
        sta up
        lda #>engram
        sta up+1
@run:   ldy #0
        lda (up),y              ; first word, 0 = end
        beq @done
        sta waddr
        iny
        lda (up),y
        sta cnt
@word:  lda waddr
        sta EADDR
        inc waddr
        iny
        lda (up),y
        sta EW0
        iny
        lda (up),y
        sta EW1
        iny
        lda (up),y
        sta EW2
        iny
        lda (up),y
        sta EWRITE
        dec cnt
        bne @word
        iny
        tya
        clc
        adc up
        sta up
        bcc @run
        inc up+1
        jmp @run
@done:  lda #7                  ; the extension page (XPAGE): all 128 words
        sta ECONF
        lda #<extram
        sta up
        lda #>extram
        sta up+1
        lda #0
        sta waddr
@xw:    lda waddr
        sta EADDR
        ldy #0
        lda (up),y
        sta EW0
        iny
        lda (up),y
        sta EW1
        iny
        lda (up),y
        sta EW2
        iny
        lda (up),y
        sta EWRITE
        lda up
        clc
        adc #4
        sta up
        bcc :+
        inc up+1
:       inc waddr
        bpl @xw
        lda #3
        sta ECONF
        rts

; Rev C features on or off (revc), with the engine and the chip idle: unlock (and reset the
; coefficients) or lock (which clears them, and puts the original noise voice types back)
ext_mode:
:       bit ESTAT
        bmi :-
:       bit AMY
        bmi :-
        lda revc
        beq @lock
        lda #$A5
        sta AMY+7
        lda #$5A
        sta AMY+7
        jsr wrA0
        lda #0
        jsr wrB
        jsr wrC
        lda #$39                ; EXT_RESET
        jmp wr0
@lock:  lda #0
        sta AMY+7
        ldx #0
:       lda vtypes,x
        jsr wrA
        txa
        ora #WRVTYP
        jsr wr0
        inx
        cpx #8
        bne :-
        rts

; OPTION: the new mode, then each voice's instrument again (sent with or without the
; extension data; a select silences the voice)
set_mode:
        jsr ext_mode
        ldx #0
:       lda vinst,x
        sta EW0
        txa
        ora #$A0
        jsr post
        inx
        cpx #8
        bne :-
        jmp show_mode

; ---------------------------------------------------------------------------
; the Atari program
start:  ldx #1                  ; PAL: GTIA says 1 in bits 1-3
        lda PALREG
        and #$0E
        bne :+
        dex
:       stx ntsc
        lda vwrap_t,x
        sta vwrap
        lda #6
        sta skip
        jsr chip_init
        jsr eng_init
        lda #1                  ; Rev C features on: unlocked before the first tune's selects
        sta revc
        jsr ext_mode
        jsr clear
        ldy #0
        ldx #0
        jsr text
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
        ldy #5*40+21
        ldx #t_mode - texts
        jsr text
        jsr show_mode
        lda #0
        sta maxl
        sta phase
        jsr start_tune
        jsr show_tune
        lda #7                  ; deferred VBI
        ldy #<vbi
        ldx #>vbi
        jsr SETVBV

@loop:  jsr service
        lda maxl
        asl a
        ldy #5*40+17
        jsr hex2
        lda CONSOL
        and #4                  ; OPTION: Rev C on/off, at the next frame
        bne @nopt
        lda revc
        eor #1
        sta revc
        lda #1
        sta reqx
:       jsr service
        lda CONSOL
        and #4
        beq :-
@nopt:  lda CONSOL
        and #3
        cmp #3
        beq @loop
        tax                     ; 2 START: next, 1 SELECT: previous
        lda tune
        cpx #2
        bne @prev
        clc
        adc #1
        cmp #NTUNES
        bcc @set
        lda #0
        beq @set
@prev:  sec
        sbc #1
        bcs @set
        lda #NTUNES - 1
@set:   sta nexttune
:       jsr service
        lda CONSOL
        and #3
        cmp #3
        bne :-
        jmp @loop

; The VBI only says a frame is due; the main loop runs it on screen (line RASTER) with
; the background in colour while the player runs, a raster-time bar (in the VBI itself
; the colour would never show).  Calling play from a VBI works the same.
vbi:    lda ntsc                ; NTSC: every sixth VBI does nothing
        beq :+
        dec skip
        bne :+
        lda #6
        sta skip
        jmp XITVBV
:       lda #1
        sta fdue
        jmp XITVBV

service:
        lda fdue
        beq @no
:       lda VCOUNT
        cmp #RASTER
        bne :-
        lda #RCOLOUR
        sta COLBK
        sta COLPF2
        lda VCOUNT
        sta vc0
        lda reqx
        beq :+
        lda #0
        sta reqx
        jsr set_mode
:       lda nexttune
        bmi :+
        jsr start_tune
        jsr show_tune
:       jsr play
        lda COLOR4
        sta COLBK
        lda COLOR2
        sta COLPF2
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

show_tune:
        ldx tune                ; name: 36 characters at row 2
        lda tname_lo,x
        sta up
        lda tname_hi,x
        sta up+1
        lda #0
        sta cnt
:       ldy cnt
        lda (up),y
        pha
        tya
        clc
        adc #2*40+2
        tay
        pla
        jsr scr
        inc cnt
        lda cnt
        cmp #36
        bne :-
        lda #0
        sta maxl
        rts

show_mode:
        ldx #t_on - texts
        lda revc
        bne :+
        ldx #t_off - texts
:       ldy #5*40+35
        jmp text

clear:  lda SAVMSC
        sta scrp
        lda SAVMSC+1
        sta scrp+1
        ldx #3
        ldy #0
        tya
:       sta (scrp),y
        iny
        bne :-
        inc scrp+1
        dex
        bne :-
        rts

text:   lda texts,x
        beq :+
        jsr scr
        inx
        iny
        bne text
:       rts

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
texts:  .byte "  AMY VERSIONS OF ATARI CLASSICS", 0
t_none: .byte "  NO AMY NOTE ENGINE IN THIS POKEYMAX", 0
t_keys: .byte "  START NEXT TUNE, SELECT PREVIOUS", 0
t_lines: .byte "  VBI LINES MAX $", 0
t_mode: .byte "OPTION: REV C", 0
t_on:   .byte "ON ", 0
t_off:  .byte "OFF", 0

        .include "convset.inc"          ; the tune set: build/setN/convset.inc (build.sh)
