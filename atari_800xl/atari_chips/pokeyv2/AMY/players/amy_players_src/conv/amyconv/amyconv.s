; amyconv.s: AMY arrangements of POKEY classics, played from a VBI through the PokeyMAX copper
; note engine (a copper++ program in the sample RAM, loaded by the XEX's first segment, that
; does what the AMY note engine did: 8 voices x 8 harmonics, INDIVIDUAL mode, AMY Rev. C at
; 8.192 MHz).  Each engine event is a copper start on the voice's thread.
;
; Per frame the VBI first sends the vibrato (frequency jumps, each a copper start on the
; voice), then reads the tune's stream until a wait and sends its events:
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
; (the kick's exponential drop) and per-harmonic detune and diffusion (the copper's entries
; for that mode).  Off: locked, the original noise types, exactly the Rev B sound.
;
; Entry points at the start of CODE (the cycle-count harness calls them):
;   +0 start  +3 chip_init  +6 cop_init  +9 start_tune (A = tune)  +12 play  +15 ext_mode

        .setcpu "6502"
        .export start, nexttune

AMY     = $D2C0                 ; +0 command/status, 1-3 A/B/C, 4-6 wrapper, 7 Rev C unlock
CCTRL   = $D295                 ; the copper: bit 0 run, bit 1 stop all; read bit 6: a start waits
CADDRL  = $D296
CADDRH  = $D297
CSTART  = $D298
CTICKL  = $D29B
CTICKH  = $D29C
CBASE   = $D29D
CPARAM  = $D29E

        .include "copper_conv.inc"      ; the copper note engine's entries (copgen.py)

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

.ifndef ZPVARS
        .bss                    ; (test build ZPVARS: the variables in zero page instead)
.endif
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
tmp:    .res 1
looping: .res 1                 ; 1 from the stream's end to its first wait: skip instrument events
off:    .res 1
vinst:  .res 8                  ; per voice: its instrument (for re-selecting)
revc:   .res 1                  ; Rev C features on
reqx:   .res 1                  ; set by OPTION: apply revc at the next frame
hm2:    .res 1                  ; the band limit of the last $48 note ($68 notes keep it)
copok:  .res 1                  ; the copper is there
cpage:  .res 1                  ; the mode's page of entries (the combined ones: the next)
hv:     .res 1                  ; the held event: voice, $FF = none
hop:    .res 1                  ;   1 select, 2 on, 3 off
hi:     .res 1                  ;   instrument
hn:     .res 1                  ;   an on's note, level, band limit
hl:     .res 1
hh:     .res 1
evop:   .res 1
vlo:    .res 1
vhi:    .res 1

        .code
entry:  jmp start
        jmp chip_init
        jmp cop_init
        jmp start_tune
        jmp play
        jmp ext_mode

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
        jmp flush               ; the frame's events are done: the held one goes
@ev:    cmp #$48
        bcs @on
        and #7                  ; $40+v: off
        tax
        lda #$FF
        sta vnote,x
        lda #3
        jsr ev
        jmp @next
@on:    cmp #$50
        bcs @vib
        and #7                  ; $48+v: on, note, level
        tax
        jsr getb
        sta vnote,x
        tay
        lda hmtab,y
        sta hm2
        jsr getb
        sta tmp
        lda #2
        jsr ev
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
        lda #1
        jsr ev
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
@onk:   and #7                  ; $68+v: on, note, level; the band limit as it is
        tax
        jsr getb
        sta vnote,x
        jsr getb
        sta tmp
        lda #2
        jsr ev
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

; a copper start: thread X at entry A (in the mode's page), once the start latch is free (the
; previous start has been taken: its thread was at rest)
go:     bit CCTRL
        bvs go
        sta CADDRL
        stx CSTART
        rts

; note on, voice X: note vnote,x, level tmp, band limit hm2; the voice's instrument's entry
on:     bit CCTRL
        bvs on
        lda vnote,x
        sta CPARAM
        lda tmp
        sta CPARAM
        lda hm2
        sta CPARAM
        ldy vinst,x
        lda on_lo,y
        sta CADDRL
        stx CSTART
        rts

; An event for voice X (A: 1 select, 2 on, 3 off; the instrument vinst,x; an on's note vnote,x,
; level tmp, band limit hm2).  The last event is held back: when this one is for the same voice
; and instrument, the two go as one start of a combined entry (select then on, on then off, two
; ons with the same band limit, off then on), so the 6502 doesn't wait for the copper to finish
; the first; otherwise the held one goes, and this one is held.  flush sends the held event.
ev:     sta evop
        cpx hv
        bne @hold0
        lda vinst,x
        cmp hi
        beq @same
@hold0: jmp @hold
@same:  lda evop
        cmp #2
        bne @off
        lda hop                 ; an on
        cmp #1
        beq @selon
        cmp #3
        beq @offon
        lda hh                  ; on, on: legato, if the band limit is the same
        cmp hm2
        bne @hold
        jsr wlatch
        jsr hpar
        lda vnote,x
        sta CPARAM
        lda tmp
        sta CPARAM
        ldy hi
        lda on2_lo,y
        jmp @go2
@selon: ldy hi
        lda selon_lo,y
        jmp @new
@offon: ldy hi
        lda offon_lo,y
@new:   jsr wlatch
        pha
        lda vnote,x
        sta CPARAM
        lda tmp
        sta CPARAM
        lda hm2
        sta CPARAM
        pla
        jmp @go2
@off:   cmp #3
        bne @hold
        lda hop                 ; on, off: the held on's parameters
        cmp #2
        bne @hold
        jsr wlatch
        jsr hpar
        ldy hi
        lda onoff_lo,y
@go2:   ldy #$FF
        sty hv
        ldy cpage               ; the combined entries' page
        iny
        sty CADDRH
        sta CADDRL
        stx CSTART
        dey
        sty CADDRH              ; (taken with the start: back to the mode's page)
        rts
@hold:  jsr flush
        stx hv
        lda evop
        sta hop
        lda vinst,x
        sta hi
        lda vnote,x
        sta hn
        lda tmp
        sta hl
        lda hm2
        sta hh
.ifdef NOMERGE
        jmp flush               ; (test build: nothing held, every event goes at once)
.else
        rts
.endif

; send the held event (keeps X)
flush:  ldy hv
        bmi @no
        txa
        pha
        tya
        tax
        lda #$FF
        sta hv
        ldy hi
        lda hop
        cmp #2
        beq @on
        cmp #1
        beq @sel
        lda off_lo,y
        jsr go
        jmp @r
@sel:   lda sel_lo,y
        jsr go
        jmp @r
@on:    jsr wlatch
        jsr hpar
        lda on_lo,y
        sta CADDRL
        stx CSTART
@r:     pla
        tax
@no:    rts

; the held on's parameters (the latch is free)
hpar:   lda hn
        sta CPARAM
        lda hl
        sta CPARAM
        lda hh
        sta CPARAM
        rts

; until the start latch is free
wlatch: bit CCTRL
        bvs wlatch
        rts

; the entries of each instrument (the same in both modes' pages)
on_lo:  .repeat COP_NINST, I
        .byte COP_ON0 + COP_STRIDE * I
        .endrep
off_lo: .repeat COP_NINST, I
        .byte COP_OFF0 + COP_STRIDE * I
        .endrep
sel_lo: .repeat COP_NINST, I
        .byte COP_SEL0 + COP_STRIDE * I
        .endrep
selon_lo: .repeat COP_NINST, I
        .byte COP_SELON0 + COP_STRIDE * I
        .endrep
onoff_lo: .repeat COP_NINST, I
        .byte COP_ONOFF0 + COP_STRIDE * I
        .endrep
on2_lo: .repeat COP_NINST, I
        .byte COP_ON20 + COP_STRIDE * I
        .endrep
offon_lo: .repeat COP_NINST, I
        .byte COP_OFFON0 + COP_STRIDE * I
        .endrep

; vibrato: voices with a depth and a note get the note's pitch + lfo, as a jump: a copper
; start on the voice (vib entry: R0 = C, the low byte, R1 = B, the high byte).  The 6502
; can't write the chip itself while the copper may be in the middle of a command.
vibrato:
        lda phase               ; the lfo changes on odd frames
        lsr a
        bcc @done
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
        sta vlo                 ; C
        lda ftab_hi,y
        adc #0
        jmp @hi
@neg:   adc ftab_lo,y
        sta vlo
        lda ftab_hi,y
        adc #$FF
@hi:    and #$1F
        sta vhi                 ; B
:       bit CCTRL
        bvs :-
        lda vlo
        sta CPARAM
        lda vhi
        sta CPARAM
        lda #COP_VIB            ; a frequency jump
        sta CADDRL
        stx CSTART
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
        ldy #$FF                ; no held event (the threads stop here)
        sty hv
        lda #3                  ; the copper's threads stop: the 6502 writes the chip here
        sta CCTRL
:       bit AMY                 ; the chip idle?
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
        lda #$FF                ; no held event
        sta hv
        jsr cop_detect
        lda copok
        beq :+
        lda #3                  ; the copper's threads stop first (they may be playing still)
        sta CCTRL
:       lda #0
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

; the copper: every thread stopped, a 1 ms tick, AMY's registers, the entries of the mode,
; then each voice's constants (vinit: R0 = 8 v, R1 = v).  copok = 0 if there's no copper.
cop_init:
        lda copok
        beq @done
        lda #3
        sta CCTRL               ; stop every thread, keep running
        lda #16                 ; 16 scanlines: 1 ms
        sta CTICKL
        lda #0
        sta CTICKH
        lda #$C0
        sta CBASE
        jsr cop_page
        ldx #0
@v:     bit CCTRL
        bvs @v
        txa
        asl a
        asl a
        asl a
        sta CPARAM
        stx CPARAM
        lda #COP_VINIT
        sta CADDRL
        stx CSTART
        inx
        cpx #8
        bne @v
@done:  rts

; Is the copper there?  A PokeyMAX ($D21C reads $01 with the configuration mapped), a core with
; the 32-byte window (RESTRICT bit 7 reads 0: older cores read 1 there and have no CAPABILITY2),
; and CAPABILITY2 says copper and 64 KiB sample RAM.  copok = 1 if so.  Nothing writes the
; copper's registers otherwise: on an older core they are POKEY 1 shadows (SEROUT among them).
cop_detect:
        lda #$3F
        sta $D20C               ; the configuration window in
        ldx #0
        lda $D21C
        cmp #1
        bne @no
        lda $D217               ; RESTRICT
        bmi @no
        lda $D220               ; CAPABILITY2
        and #6
        cmp #6
        bne @no
        inx
@no:    lda #0
        sta $D20C               ; and out
        stx copok
        rts

; the entries of the mode (revc): their page
cop_page:
        lda #COP_PAGE_X
        ldy revc
        bne :+
        lda #COP_PAGE_L
:       sta CADDRH
        sta cpage
        rts

; Rev C features on or off (revc): the copper's threads stopped and the chip idle, unlock (and
; reset the coefficients) or lock (which clears them, and puts the original noise voice types
; back); the copper's entries for the mode
ext_mode:
        lda #3
        sta CCTRL
:       bit AMY
        bmi :-
        jsr cop_page
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
:       ldy vinst,x
        lda sel_lo,y
        jsr go
        inx
        cpx #8
        bne :-
        jmp show_mode

; ---------------------------------------------------------------------------
; the Atari program
        .import __BSS_RUN__, __BSS_SIZE__
        .assert __BSS_SIZE__ < 256, error, "BSS: the clear loop below takes 255 bytes at most"
start:  lda #0                  ; the variables start at 0 (the loader leaves whatever was there:
        ldx #<__BSS_SIZE__      ; OPTION's reqx, read on the first frame, above all)
        beq @bss
:       sta __BSS_RUN__-1,x
        dex
        bne :-
@bss:   ldx #1                  ; PAL: GTIA says 1 in bits 1-3
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
        jsr cop_init
        jsr clear
        ldy #0
        ldx #0
        jsr text
        lda copok
        bne :+
        ldy #2*40
        ldx #t_none - texts
        jsr text
@halt:  jmp @halt
:       lda #1                  ; Rev C features on: unlocked before the first tune's selects
        sta revc
        jsr ext_mode
        ldy #4*40
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
t_none: .byte "  NO COPPER IN THIS POKEYMAX", 0
t_keys: .byte "  START NEXT TUNE, SELECT PREVIOUS", 0
t_lines: .byte "  VBI LINES MAX $", 0
t_mode: .byte "OPTION: REV C", 0
t_on:   .byte "ON ", 0
t_off:  .byte "OFF", 0

        .include "convset.inc"          ; the tune set: build/setN/convset.inc (build.sh)
