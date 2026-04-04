; PICO JAM - Tiny byte-level generative language model
; 96 -> 128 -> 45. W1: 1-bit (8/byte), W2: INT2 (4/byte).
; ~3 KB brain, sub-5 KB XEX. Marek Spanel, 2026. jam.ag

.export start
CIOV    = $E456
ICCOM   = $0342
ICBAL   = $0344
ICBAH   = $0345
ICBLL   = $0348
ICBLH   = $0349
PUTCHR  = $0B
GETREC  = $05
COLOR1  = $02C5
COLOR4  = $02C8
EOL     = $9B
CLR     = $7D
RANDOM  = $D20A
CH      = $02FC

N_IN     = 96
N_HID    = 64
N_OUT    = 45
W1_STRIDE = 12     ; 96/8 bytes per row (1-bit)
W2_STRIDE = 16     ; 64/4 bytes per row (INT2)
SEP_CHAR = $3E
MAX_GEN  = 15
MAX_INPUT = 4
EOL_IDX  = 44

W1_OFF   = 0       ; 64 * 12 = 768
W2_OFF   = 768     ; 45 * 16 = 720
B1_OFF   = 1488    ; 64
B2_OFF   = 1552    ; 45

.segment "ZEROPAGE"
acc_lo: .res 1
acc_hi: .res 1
wbyte:  .res 1
wptr:   .res 2
bptr:   .res 2
optr:   .res 2
aptr:   .res 2
wcnt:   .res 1
ocnt:   .res 1
llen:   .res 1
blo:    .res 1
bhi:    .res 1
besti:  .res 1
tmp:    .res 1
second: .res 1
slo:    .res 1
shi:    .res 1
inv_len: .res 1
nz_src: .res 2      ; pointer to source buffer (thash or hidbuf)
nz_max: .res 1      ; scan limit
stride: .res 1      ; weight row stride for generic cneuron

.segment "BSS"
iline:  .res 42
co:     .res 1
gencnt: .res 1
lastch: .res 1
repchr: .res 1
answer_ok: .res 1
ctxlen: .res 1
tc0:    .res 1
tc1:    .res 1
tc2:    .res 1
first_turn: .res 1
dream_flag: .res 1
dream_chain: .res 1  ; how many chains so far
hint_mode: .res 1    ; 1=running neural hint (answer->query)
ctx:    .res 80
thash:  .res 96
hidbuf: .res 64
frozen_thash: .res 96
frozen_len: .res 1      ; ctxlen at freeze time (query+SEP length)
obuf:   .res 90
nz_count: .res 1
nz_idx:  .res 48    ; input index (0-95 or 0-127)
nz_val:  .res 48    ; activation value

.segment "CODE"
start:
        ldx #0
        lda #0
@cb:    sta $0700,x
        sta $0800,x
        sta $0900,x
        sta $0A00,x
        inx
        bne @cb

        lda #1
        sta first_turn

        lda #CLR
        sta co
        jsr pc
        lda #<ban
        ldx #>ban
        ldy #banl
        jsr ps
        lda #<intro
        ldx #>intro
        ldy #introl
        jsr ps

mloop:
        lda #0
        sta dream_flag
        lda #<prm
        ldx #>prm
        ldy #prml
        jsr ps
        jsr rline_timeout
        bcc got_input
        jsr idle_chatter
got_input:
        ; Strip trailing punctuation
@strip: ldx llen
        beq mloop
        dex
        lda iline,x
        cmp #63
        beq @cut
        cmp #33
        beq @cut
        cmp #46
        beq @cut
        jmp @nocut
@cut:   lda #0
        sta iline,x
        stx llen
        jmp @strip
@nocut: lda llen
        beq mloop
        cmp #MAX_INPUT+1
        bcc @lenok
        lda #MAX_INPUT
        sta llen
@lenok:
        ldx #0
@cpq:   cpx llen
        beq @qd
        lda iline,x
        cmp #65
        bcc @stq
        cmp #91
        bcs @stq
        ora #$20
@stq:   sta ctx,x
        inx
        bne @cpq
@qd:    lda #SEP_CHAR
        sta ctx,x
        inx
        stx ctxlen

        jsr thash_init_frozen   ; freeze query+SEP hash for incremental L1

        ; Context decay: first turn = full clear, then decay
        lda first_turn
        beq @ctx_decay
        jsr thash_clear     ; first interaction: clean slate
        lda #0
        sta first_turn
        jmp @ctx_done
@ctx_decay:
        jsr thash_decay     ; subsequent: old context fades
@ctx_done:

        ldx ctxlen
        dex
        lda ctx,x
        sta tc2
        dex
        lda ctx,x
        sta tc1
        dex
        bmi @tc_ok
        lda ctx,x
        sta tc0
@tc_ok:
        lda #0
        sta gencnt
        sta repchr
        lda #$FF
        sta lastch
        ; Dream prefix "... " or normal " "
        lda dream_flag
        beq @npfx
        lda #'.'
        sta co
        jsr pc
        jsr pc
        jsr pc
        lda #' '
        sta co
        jsr pc
        jmp @pfxd
@npfx:  lda #' '
        sta co
        jsr pc
@pfxd:  lda #1
        sta answer_ok

gen_loop:
        ; === INCREMENTAL HASH (frozen + live delta) ===
        ldx #0
@copyf: lda frozen_thash,x
        sta thash,x
        inx
        cpx #96
        bne @copyf
        jsr thash_add_live_delta

        ; === L1: 1-bit sparse ===
        jsr build_nz_thash
        lda #<(md + W1_OFF)
        sta wptr
        lda #>(md + W1_OFF)
        sta wptr+1
        lda #<(md + B1_OFF)
        sta bptr
        lda #>(md + B1_OFF)
        sta bptr+1
        lda #<hidbuf
        sta optr
        lda #>hidbuf
        sta optr+1
        lda #N_HID
        sta ocnt
@l1r:   jsr cneuron_1bit
        ; bias
        ldy #0
        lda (bptr),y
        ldx #0
        cmp #$80
        bcc @l1bp
        ldx #$FF
@l1bp:  clc
        adc acc_lo
        sta acc_lo
        txa
        adc acc_hi
        sta acc_hi
        ; ReLU 0-255
        lda acc_hi
        bmi @l1z
        bne @l1c
        lda acc_lo
        jmp @l1s
@l1c:   lda #255
        jmp @l1s
@l1z:   lda #0
@l1s:   ldy #0
        sta (optr),y
        inc optr
        bne @l1no
        inc optr+1
@l1no:  inc bptr
        bne @l1nb
        inc bptr+1
@l1nb:  dec ocnt
        bne @l1r

        ; === L2: INT2 sparse ===
        jsr build_nz_hidbuf
        lda #<(md + W2_OFF)
        sta wptr
        lda #>(md + W2_OFF)
        sta wptr+1
        lda #<(md + B2_OFF)
        sta bptr
        lda #>(md + B2_OFF)
        sta bptr+1
        lda #<obuf
        sta optr
        lda #>obuf
        sta optr+1
        lda #N_OUT
        sta ocnt
@l2r:   jsr cneuron_int2
        ; bias
        ldy #0
        lda (bptr),y
        ldx #0
        cmp #$80
        bcc @l2bp
        ldx #$FF
@l2bp:  clc
        adc acc_lo
        sta acc_lo
        txa
        adc acc_hi
        sta acc_hi
        ; store 16-bit
        ldy #0
        lda acc_lo
        sta (optr),y
        iny
        lda acc_hi
        sta (optr),y
        clc
        lda optr
        adc #2
        sta optr
        bcc @l2no
        inc optr+1
@l2no:  inc bptr
        bne @l2nb
        inc bptr+1
@l2nb:  dec ocnt
        bne @l2r

        ; === Algorithmic EOL suppression ===
        lda gencnt
        cmp #3
        bcs @eol_mid
        ; pos < 3: subtract 40 from EOL logit
        sec
        lda obuf + EOL_IDX * 2
        sbc #40
        sta obuf + EOL_IDX * 2
        lda obuf + EOL_IDX * 2 + 1
        sbc #0
        sta obuf + EOL_IDX * 2 + 1
        jmp @eol_done
@eol_mid:
        cmp #8
        bcs @eol_late
        ; pos 3-7: subtract 15
        sec
        lda obuf + EOL_IDX * 2
        sbc #15
        sta obuf + EOL_IDX * 2
        lda obuf + EOL_IDX * 2 + 1
        sbc #0
        sta obuf + EOL_IDX * 2 + 1
        jmp @eol_done
@eol_late:
        ; pos 12+: progressive EOL boost
        cmp #12
        bcc @eol_done
        sec
        sbc #12
        asl
        asl
        asl
        asl
        clc
        adc #16
        clc
        adc obuf + EOL_IDX * 2
        sta obuf + EOL_IDX * 2
        lda #0
        adc obuf + EOL_IDX * 2 + 1
        sta obuf + EOL_IDX * 2 + 1
@eol_done:

        jsr amax45

        ; Confidence (first char only)
        lda gencnt
        bne @conf_ok
        sec
        lda blo
        sbc slo
        sta tmp
        lda bhi
        sbc shi
        bne @conf_ok
        lda tmp
        cmp #3
        bcs @conf_ok
        jmp gen_unsure
@conf_ok:
        lda besti
        cmp #EOL_IDX
        bne @not_eol
        jmp gen_done
@not_eol:
        ldx besti
        lda charset,x
        sta co
        cmp lastch
        bne @newch
        inc repchr
        lda repchr
        cmp #4           ; allow 3 repeats (e.g. "000" in bin 8)
        bcc @printch
        jmp gen_fallback
@newch: sta lastch
        lda #1
        sta repchr
@printch:
        ; Thinking effect (margin < 8: flash second)
        sec
        lda blo
        sbc slo
        sta tmp
        lda bhi
        sbc shi
        bne @no_think
        lda tmp
        cmp #8
        bcs @no_think
        lda second
        cmp #EOL_IDX
        beq @no_think
        tax
        lda charset,x
        ora #$80
        sta co
        jsr pc
        ldx #3
@twait: lda $14
@tw2:   cmp $14
        beq @tw2
        dex
        bne @twait
        lda #$7E
        sta co
        jsr pc
        ldx besti
        lda charset,x
        sta co
@no_think:
        ; Dream: inverse output + delay + keycheck
        lda dream_flag
        beq @no_dinv
        lda co
        ora #$80
        sta co
        jsr pc
        lda $14
@dw1:   cmp $14
        beq @dw1
        lda $14
@dw2:   cmp $14
        beq @dw2
        lda CH
        cmp #$FF
        bne @dream_abort
        jmp @after_print
@dream_abort:
        lda #EOL
        sta co
        jsr pc
        jmp mloop
@no_dinv:
        jsr pc
@after_print:
        lda co
        and #$7F
        ldx ctxlen
        sta ctx,x
        inx
        stx ctxlen
        inc gencnt
        lda gencnt
        cmp #MAX_GEN
        bcc @notdone
        jmp gen_done
@notdone:
        jmp gen_loop

gen_unsure:
        lda dream_flag
        beq @not_dream_u
        jmp gen_done
@not_dream_u:
        lda hint_mode
        beq @not_hint_u
        jmp gen_done_hint
@not_hint_u:
        lda #0
        sta answer_ok
        lda $14
        and #3
        pha
        asl
        tax
        lda us_ptrs,x
        sta aptr
        lda us_ptrs+1,x
        sta aptr+1
        pla
        tax
        lda us_lens,x
        tay
        jsr ps_inv
        lda #EOL
        sta co
        jsr pc
        jmp gen_done

gen_fallback:
        lda dream_flag
        beq @not_dream_f
        jmp gen_done
@not_dream_f:
        lda hint_mode
        beq @not_hint_f
        jmp gen_done_hint
@not_hint_f:
        lda #0
        sta answer_ok
        ldx repchr
        dex
@bksp:  lda #$7E
        sta co
        txa
        pha
        jsr pc
        pla
        tax
        dex
        bne @bksp
        lda #EOL
        sta co
        jsr pc
        lda #$20
        sta co
        jsr pc
        lda $14
        and #1
        pha
        asl
        tax
        lda fb_ptrs,x
        sta aptr
        lda fb_ptrs+1,x
        sta aptr+1
        pla
        tax
        lda fb_lens,x
        tay
        jsr ps_inv

gen_done_hint:
        lda #0
        sta hint_mode
        lda #EOL
        sta co
        jsr pc
        jmp mloop

gen_done:
        lda #EOL
        sta co
        jsr pc
        lda dream_flag
        beq @not_dreaming
        ; === Dream chaining: feed answer back as next query ===
        ; Find separator in ctx, copy everything after it to iline
        ldx #0
@dfs:   lda ctx,x
        cmp #SEP_CHAR
        beq @dfound
        inx
        cpx ctxlen
        bne @dfs
        jmp @dream_end       ; no separator? stop
@dfound:
        inx                  ; skip '>'
        ldy #0
@dcpy:  cpx ctxlen
        beq @dcpd
        lda ctx,x
        sta iline,y
        inx
        iny
        cpy #MAX_INPUT
        bcc @dcpy
@dcpd:  lda #0
        sta iline,y
        sty llen
        ; Stop if answer was empty or too short
        cpy #2
        bcc @dream_end
        ; Max 3 chains
        inc dream_chain
        lda dream_chain
        cmp #3
        bcs @dream_end
        ; Pause 1-2 seconds between dream chains
        ldx #60              ; ~60 frames = 1.2 sec
@dpause:
        lda $14
@dpw:   cmp $14
        beq @dpw
        ; Check keypress during pause
        lda CH
        cmp #$FF
        bne @dream_end
        dex
        bne @dpause
        ; Chain: go back to process iline as new query
        jmp got_input
@dream_end:
        lda #0
        sta dream_flag
        jmp mloop

@not_dreaming:
        lda answer_ok
        beq @no_sug
        lda gencnt
        cmp #7
        bcs @no_sug
        lda $14
        and #7
        cmp #3
        bcs @no_sug
        lda $14
        lsr
        lsr
        lsr
        and #7
        pha
        lda #$20
        sta co
        jsr pc
        jsr pc
        pla
        pha
        asl
        tax
        lda sug_ptrs,x
        sta aptr
        lda sug_ptrs+1,x
        sta aptr+1
        pla
        tax
        lda sug_lens,x
        tay
        jsr ps_inv
        lda #EOL
        sta co
        jsr pc
@no_sug:
        ; === Neural Hint: 25% chance to feed answer back as query ===
        lda hint_mode
        bne @hint_skip       ; no recursion
        lda answer_ok
        beq @hint_skip       ; skip after fallback
        lda gencnt
        cmp #2
        bcc @hint_skip       ; skip 1-char answers
        lda RANDOM
        and #$03
        bne @hint_skip       ; 25% chance

        ; Copy answer from ctx (after '>') to iline
        ldx #0
@hfs:   lda ctx,x
        cmp #SEP_CHAR
        beq @hfound
        inx
        cpx ctxlen
        bne @hfs
        jmp @hint_skip       ; no separator
@hfound:
        inx                  ; skip '>'
        ldy #0
@hcopy: cpx ctxlen
        beq @hend
        lda ctx,x
        sta iline,y
        inx
        iny
        cpy #MAX_INPUT
        bcc @hcopy
@hend:  lda #0
        sta iline,y
        sty llen
        cpy #1
        bcc @hint_skip       ; empty answer
        ; Setup hint mode
        lda #1
        sta hint_mode
        ; Print leading space
        lda #' '
        sta co
        jsr pc
        jmp got_input        ; process answer as new query
@hint_skip:
        lda #0
        sta hint_mode
        jmp mloop

; =====================================================
; RLINE WITH TIMEOUT (15-35 sec)
; =====================================================
rline_timeout:
        lda #$FF
        sta CH
        lda RANDOM
        asl
        asl
        sta tmp
        lda #0
        rol
        sta wbyte
        clc
        lda tmp
        adc #<750
        sta tmp
        lda wbyte
        adc #>750
        sta wbyte
        lda #0
        sta acc_lo
        sta acc_hi
@wait:  lda CH
        cmp #$FF
        bne @key
        lda $14
@wf:    cmp $14
        beq @wf
        inc acc_lo
        bne @wc
        inc acc_hi
@wc:    lda acc_hi
        cmp wbyte
        bcc @wait
        bne @tout
        lda acc_lo
        cmp tmp
        bcc @wait
@tout:  sec
        rts
@key:   jsr rline
        clc
        rts

; =====================================================
; DREAM: pick random suggestion keyword, feed as query
; =====================================================
idle_chatter:
        lda RANDOM
        and #7
        pha
        asl
        tax
        lda sug_ptrs,x
        sta aptr
        lda sug_ptrs+1,x
        sta aptr+1
        pla
        tax
        lda sug_lens,x
        sec
        sbc #4
        sta llen
        ldy #4
        ldx #0
@dcp:   cpx llen
        beq @dcd
        lda (aptr),y
        cmp #65
        bcc @dst
        cmp #91
        bcs @dst
        ora #$20
@dst:   sta iline,x
        iny
        inx
        jmp @dcp
@dcd:   lda #0
        sta iline,x
        lda #1
        sta dream_flag
        lda #0
        sta dream_chain
        clc
        rts

; =====================================================
; HASH
; =====================================================
; =====================================================
; TRIGRAM HASH SUBROUTINE (shared by full hash and incremental)
; Input: tc0, tc1, tc2
; Output: increments thash[idx] where idx = (tc0*31 + tc1*7 + tc2) & $3F
; =====================================================
tri_one:
        lda tc0
        asl
        asl
        asl
        asl
        asl
        sec
        sbc tc0
        sta acc_lo
        lda tc1
        asl
        asl
        asl
        sec
        sbc tc1
        clc
        adc acc_lo
        clc
        adc tc2
        and #$3F
        tax
        inc thash,x
        rts

; Same as tri_one but increments frozen_thash instead of thash
tri_one_frozen:
        lda tc0
        asl
        asl
        asl
        asl
        asl
        sec
        sbc tc0
        sta acc_lo
        lda tc1
        asl
        asl
        asl
        sec
        sbc tc1
        clc
        adc acc_lo
        clc
        adc tc2
        and #$3F
        tax
        inc frozen_thash,x
        rts

; =====================================================
; INCREMENTAL HASH - FROZEN + LIVE DELTA (bit-exact)
; =====================================================

; Compute frozen_thash from query+SEP (called once after got_input)
thash_init_frozen:
        lda ctxlen
        sta frozen_len          ; remember query+SEP length
        ldx #0
        lda #0
@clr:   sta frozen_thash,x
        inx
        cpx #96
        bne @clr

        ; Trigrams over query+SEP
        lda ctxlen
        cmp #3
        bcc @bagq
        ldx #0
@loop:  lda ctx,x
        sta tc0
        lda ctx+1,x
        sta tc1
        lda ctx+2,x
        sta tc2
        txa
        pha
        jsr tri_one_frozen
        pla
        tax
        inx
        txa
        clc
        adc #2
        cmp ctxlen
        bcs @bagq
        txa
        tax
        jmp @loop

        ; Bag-of-chars over query+SEP
@bagq:  ldx #0
@bag:   cpx ctxlen
        beq @bagdone
        lda ctx,x
        and #$0F
        tay
        lda frozen_thash+64,y
        cmp #255
        beq @bsat
        clc
        adc #1
        sta frozen_thash+64,y
@bsat:  inx
        jmp @bag
@bagdone:
        rts

; Add all answer-portion contributions on top of thash
; (thash already has frozen copy; ctxlen includes answer chars)
thash_add_live_delta:
        ; Trigrams: iterate from (frozen_len - 2) to (ctxlen - 3)
        ; These are all trigrams that involve at least one answer char
        lda ctxlen
        cmp #3
        bcc @bag_start
        lda frozen_len
        sec
        sbc #2
        bcs @tri_idx
        lda #0              ; clamp to 0
@tri_idx:
        tax
@tri_loop:
        txa
        clc
        adc #2
        cmp ctxlen
        bcs @bag_start      ; i+2 >= ctxlen => done
        lda ctx,x
        sta tc0
        lda ctx+1,x
        sta tc1
        lda ctx+2,x
        sta tc2
        txa
        pha
        jsr tri_one
        pla
        tax
        inx
        jmp @tri_loop

        ; Bag: add entries for all answer chars (frozen_len to ctxlen-1)
@bag_start:
        ldx frozen_len
@bag:   cpx ctxlen
        beq @bag_done
        lda ctx,x
        and #$0F
        tay
        lda thash+64,y
        cmp #255
        beq @bsat2
        clc
        adc #1
        sta thash+64,y
@bsat2: inx
        jmp @bag
@bag_done:
        ; Suffix features (gencnt-dependent)
        lda gencnt
        beq @sfxd
        ldx ctxlen
        dex
        lda ctx,x
        and #7
        clc
        adc #80
        tax
        inc thash,x
        lda gencnt
        and #7
        clc
        adc #88
        tax
        inc thash,x
@sfxd:  rts

thash_clear:
        ; Full clear (first turn or dream)
        ldx #0
        lda #0
@clr:   sta thash,x
        inx
        cpx #96
        bne @clr
        rts

thash_decay:
        ; Decay: shift right by 1 (old context fades, doesn't vanish)
        ldx #0
@dec:   lda thash,x
        lsr
        sta thash,x
        inx
        cpx #96
        bne @dec
        rts

thash_hash:
        lda ctxlen
        cmp #3
        bcc @done
        ldx #0
@loop:  lda ctx,x
        sta tc0
        lda ctx+1,x
        sta tc1
        lda ctx+2,x
        sta tc2
        txa
        pha
        jsr tri_one
        pla
        tax
        inx
        txa
        clc
        adc #2
        cmp ctxlen
        bcs @done
        txa
        tax
        jmp @loop
@done:
        ldx #0
@bag:   cpx ctxlen
        beq @bdone
        lda ctx,x
        and #$0F
        tay
        lda thash+64,y
        cmp #255
        beq @bsat
        clc
        adc #1
        sta thash+64,y
@bsat:  inx
        jmp @bag
@bdone:
        lda gencnt
        beq @sfxd
        ldx ctxlen
        dex
        lda ctx,x
        and #7
        clc
        adc #80
        tax
        inc thash,x
        lda gencnt
        and #7
        clc
        adc #88
        tax
        inc thash,x
@sfxd:  rts

; =====================================================
; BUILD NZ LISTS
; =====================================================
build_nz_thash:
        lda #0
        sta nz_count
        tax
@bn:    cpx #96
        beq @bd
        lda thash,x
        beq @bs
        ldy nz_count
        cpy #48
        bcs @bs
        txa
        sta nz_idx,y
        lda thash,x
        sta nz_val,y
        inc nz_count
@bs:    inx
        jmp @bn
@bd:    rts

build_nz_hidbuf:
        lda #0
        sta nz_count
        tax
@bn:    lda hidbuf,x
        beq @bs
        ldy nz_count
        cpy #48
        bcs @bs
        txa
        sta nz_idx,y
        lda hidbuf,x
        sta nz_val,y
        inc nz_count
@bs:    inx
        cpx #N_HID
        bne @bn
        rts

; =====================================================
; 1-BIT NEURON (W1): bit=1 -> +val, bit=0 -> -val
; nz_idx = input index, nz_val = activation
; wptr -> weight row (12 bytes = 96 bits)
; =====================================================
cneuron_1bit:
        lda #0
        sta acc_lo
        sta acc_hi
        sta wcnt
@sl:    ldx wcnt
        cpx nz_count
        beq @sd
        ; byte offset = nz_idx / 8, bit = nz_idx & 7
        lda nz_idx,x
        lsr
        lsr
        lsr              ; /8 = byte offset
        tay
        lda (wptr),y     ; weight byte
        sta wbyte
        lda nz_idx,x
        and #7           ; bit position
        tay
        lda wbyte
        ; shift right Y times to get bit into carry
        cpy #0
        beq @got
@sh:    lsr
        dey
        bne @sh
@got:   lsr              ; bit -> carry
        ldx wcnt
        bcs @add         ; bit=1: add
        ; bit=0: subtract
        sec
        lda acc_lo
        sbc nz_val,x
        sta acc_lo
        bcs @snxt
        dec acc_hi
        jmp @snxt
@add:   clc
        lda acc_lo
        adc nz_val,x
        sta acc_lo
        bcc @snxt
        inc acc_hi
@snxt:  inc wcnt
        jmp @sl
@sd:    ; Advance wptr by W1_STRIDE
        clc
        lda wptr
        adc #W1_STRIDE
        sta wptr
        bcc @nw
        inc wptr+1
@nw:    rts

; =====================================================
; INT2 NEURON (W2): 00=0, 01=-1, 10=+1, 11=-2
; nz_idx = hidden index, nz_val = activation
; =====================================================
cneuron_int2:
        lda #0
        sta acc_lo
        sta acc_hi
        sta wcnt
@sl:    ldx wcnt
        cpx nz_count
        bne @cont
        jmp @sd
@cont:
        ; byte offset = nz_idx / 4, pair = nz_idx & 3
        lda nz_idx,x
        lsr
        lsr              ; /4
        tay
        lda (wptr),y
        beq @snxt        ; all 4 zero
        sta wbyte
        lda nz_idx,x
        and #3
        beq @p0
        cmp #1
        beq @p1
        cmp #2
        beq @p2
        lda wbyte
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        and #3
        jmp @got
@p2:    lda wbyte
        lsr
        lsr
        lsr
        lsr
        and #3
        jmp @got
@p1:    lda wbyte
        lsr
        lsr
        and #3
        jmp @got
@p0:    lda wbyte
        and #3
@got:   beq @snxt
        cmp #2
        beq @add1
        bcs @sub2
        ; code 01 = -1
        ldx wcnt
        sec
        lda acc_lo
        sbc nz_val,x
        sta acc_lo
        bcs @snxt
        dec acc_hi
        jmp @snxt
@add1:  ldx wcnt
        clc
        lda acc_lo
        adc nz_val,x
        sta acc_lo
        bcc @snxt
        inc acc_hi
        jmp @snxt
@sub2:  ldx wcnt
        lda nz_val,x
        asl
        sta tmp
        sec
        lda acc_lo
        sbc tmp
        sta acc_lo
        bcs @snxt
        dec acc_hi
@snxt:  inc wcnt
        jmp @sl
@sd:    clc
        lda wptr
        adc #W2_STRIDE
        sta wptr
        bcc @nw
        inc wptr+1
@nw:    rts

; =====================================================
; ARGMAX 45
; =====================================================
amax45:
        lda obuf
        sta blo
        lda obuf+1
        sta bhi
        lda #0
        sta besti
        sta slo
        lda #$80
        sta shi
        sta second
        ldx #1
@am:    txa
        asl
        tay
        sec
        lda obuf,y
        sbc blo
        lda obuf+1,y
        sbc bhi
        bvc @amc
        eor #$80
@amc:   bmi @nxt
        lda blo
        sta slo
        lda bhi
        sta shi
        lda besti
        sta second
        txa
        asl
        tay
        lda obuf,y
        sta blo
        lda obuf+1,y
        sta bhi
        stx besti
        jmp @anxt
@nxt:   txa
        asl
        tay
        sec
        lda obuf,y
        sbc slo
        lda obuf+1,y
        sbc shi
        bvc @asc
        eor #$80
@asc:   bmi @anxt
        txa
        asl
        tay
        lda obuf,y
        sta slo
        lda obuf+1,y
        sta shi
        stx second
@anxt:  inx
        cpx #N_OUT
        bne @am
        rts

; =====================================================
; I/O
; =====================================================
rline:
        ldx #0
        lda #GETREC
        sta ICCOM,x
        lda #<iline
        sta ICBAL,x
        lda #>iline
        sta ICBAH,x
        lda #40
        sta ICBLL,x
        lda #0
        sta ICBLH,x
        jsr CIOV
        ldx #0
@s:     lda iline,x
        cmp #EOL
        beq @f
        cmp #0
        beq @f
        inx
        cpx #40
        bne @s
@f:     lda #0
        sta iline,x
        stx llen
        rts

pc:     ldx #0
        lda #PUTCHR
        sta ICCOM,x
        lda #<co
        sta ICBAL,x
        lda #>co
        sta ICBAH,x
        lda #1
        sta ICBLL,x
        lda #0
        sta ICBLH,x
        jsr CIOV
        rts

ps:     stx @h+1
        pha
        ldx #0
        lda #PUTCHR
        sta ICCOM,x
        pla
        sta ICBAL,x
@h:     lda #0
        sta ICBAH,x
        tya
        sta ICBLL,x
        lda #0
        sta ICBLH,x
        jsr CIOV
        rts

ps_inv:
        sty inv_len
        ldy #0
@lp:    cpy inv_len
        beq @done
        lda (aptr),y
        ora #$80
        sta co
        tya
        pha
        jsr pc
        pla
        tay
        iny
        jmp @lp
@done:  rts

; =====================================================
.segment "RODATA"

charset:
        .byte " abcdefghijklmnopqrstuvwxyz"
        .byte "0123456789.-,!?'/"

.include "theme_pico.inc"

us0:    .byte "just ask"
us0l = * - us0
us1:    .byte "not sure"
us1l = * - us1
us2:    .byte "hmm"
us2l = * - us2
us3:    .byte "try again"
us3l = * - us3
us_ptrs: .word us0, us1, us2, us3
us_lens: .byte us0l, us1l, us2l, us3l

fb0:    .byte "beats me"
fb0l = * - fb0
fb1:    .byte "not in my 3 kb"
fb1l = * - fb1
fb_ptrs: .word fb0, fb1
fb_lens: .byte fb0l, fb1l

prm:    .byte "> "
prml = * - prm

md:
        .incbin "weights_pico.bin"
