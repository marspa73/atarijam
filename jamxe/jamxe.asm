; JAMXE - Language model on Atari 130XE (bank-switched)
; Generates text one character at a time. No lookup table.
; Architecture: 512 input -> 512 hidden (ReLU) -> 45 output (char)
; Marek Spanel, 2026. jam.ag

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
COLOR2  = $02C6
COLOR4  = $02C8
EOL     = $9B
CLR     = $7D
POKEY   = $D200
AUDF1   = POKEY + 0
AUDC1   = POKEY + 1
AUDCTL  = POKEY + 8
RANDOM  = POKEY + $0A
CH      = $02FC
NMIEN   = $D40E

; === Architecture ===
N_IN     = 512     ; 512-input XE layout with frozen query anchor
N_TRI    = 192     ; trigram hash buckets
N_HID    = 512     ; hidden neurons (4 banks x 128)
N_HID_LO = 0      ; N_HID mod 256
N_OUT    = 45      ; charset + EOL
L1_WHALF = 128     ; N_IN / 2
L2_WHALF = 0       ; N_HID / 2 = 256 (0 = 256 iterations)
STRIDE   = 128     ; bytes per W1 row
ROWS_PER_BANK = 128
N_BANKS  = 4
BANK_WIN = $4000
SEP_CHAR = $3E
MAX_GEN  = 20
MAX_INPUT = 16     ; max query length
EOL_IDX  = 44
PORTB    = $D301
PORTB_MAIN     = $B3   ; selftest off, OS on, BASIC off, CPU main, ANTIC main
PORTB_CPU_EXT0 = $A3   ; selftest off, OS on, BASIC off, CPU ext, ANTIC main, bank 0

.segment "ZEROPAGE"
acc_lo: .res 1
acc_hi: .res 1
prod_lo: .res 1
prod_hi: .res 1
act:    .res 1
mag:    .res 1
sh_lo:  .res 1
sh_hi:  .res 1
wptr:   .res 2
aptr:   .res 2
aptr_b: .res 2
bptr:   .res 2
optr:   .res 2
wcnt:   .res 1
ocnt:   .res 1
ninh:   .res 1
wbyte:  .res 1
llen:   .res 1
blo:    .res 1
bhi:    .res 1
besti:  .res 1
; gencnt: MOVED TO BSS (CIOV safe)
nibble_sel: .res 1
pptr:   .res 2
tmp:    .res 1
outi:   .res 1
; lastch, repchr: MOVED TO BSS (CIOV safe)
second: .res 1     ; second-best index
slo:    .res 1     ; second-best value lo
shi:    .res 1     ; second-best value hi
wptr2:  .res 2     ; second weight pointer (bag column)
nibsel2: .res 1    ; nibble selector for bag column

.segment "BSS"
iline:  .res 42
co:     .res 1     ; must survive CIOV
gencnt: .res 1     ; in BSS: CIOV-safe
lastch: .res 1     ; in BSS: CIOV-safe
repchr: .res 1     ; in BSS: CIOV-safe
answer_ok: .res 1   ; 1=good answer, 0=fallback/unsure
ctxlen: .res 1     ; current context length, survives pc/CIOV
tc0:    .res 1     ; trigram temps, survive pc/CIOV
tc1:    .res 1
tc2:    .res 1
tc3:    .res 1     ; suffix hash temp
vbi_cnt: .res 1    ; deferred VBI state, do not keep in OS zero page
vbi_flag: .res 1
old_vbi: .res 2
last_bucket: .res 1
first_turn: .res 1
last_bag: .res 1
inv_len: .res 1    ; ps_inv length must survive pc/CIOV
snd_ctr: .res 1
hint_mode: .res 1
dream_flag: .res 1
dream_chain: .res 1
dream_color: .res 1
cur_bank: .res 1
nmien_save: .res 1
dirty_count: .res 1
dirty_off:  .res 16       ; byte offset in W1 row (0-127) per delta
dirty_nib:  .res 16       ; nibble position (0-3)
dirty_sgn:  .res 16       ; 0=add feature, 1=subtract feature
nz_count = $2200
nz_off   = $2201    ; 128 byte offsets
nz_nib   = $2281    ; 128 nibble/pair flags
nz_pair  = nz_nib
nz_val   = $2301    ; 128 input values
frz_count = $2381
frz_off   = $2382    ; cached frozen byte offsets / hid sparse byte offsets
frz_pair  = $2402    ; cached frozen pair indices / hid sparse pair indices
frz_val   = $2482    ; cached frozen input values / hid sparse values

; === D_J Context Attention (at $2000, free main RAM) ===
CTX_SLOTS = 32
CTX_DIM   = 4
ctx_key   = $2000                     ; 128 B: query keys
ctx_val   = $2080                     ; 128 B: hidden state snapshots
ctx_age   = $2100                     ; 32 B: slot ages
ctx_query = $2120                     ; 4 B: current query vector
ctx_score = $2124                     ; 1 B
ctx_best  = $2125                     ; 1 B
ctx_wslot = $2126                     ; 1 B
FRZ_PRE   = $2600                     ; 1024 B: cached frozen+bias preacts
PREACT_RAM = $2A00                   ; 1024 B: live preacts for incremental L1
; Total: 295 B at $2000-$2126
ctx:    .res 128   ; query + > + response (expanded)
thash:  .res 192   ; legacy, kept for compatibility/debug
bhash:  .res 64    ; legacy, kept for compatibility/debug
hidbuf: .res 512   ; N_HID   ; hidden activations
obuf:   .res 90    ; 45 * 2 byte output
ihash:  .res 1024   ; 512 live+frozen feature bytes, scratch-built each turn

.segment "CODE"
start:
        lda #PORTB_MAIN
        sta PORTB

        ; Clear ALL BSS (XL: larger buffers)
        ldx #0
        lda #0
@cb:    sta $0500,x
        sta $0600,x
        sta $0700,x
        sta $0800,x
        sta $0900,x
        sta $0A00,x
        sta $0B00,x
        sta $0C00,x
        inx
        bne @cb
        ldx #$80
@cb2:   sta $0400,x
        inx
        bne @cb2

        ; Clear D_J attention + nz_list ($2000-$22C0)
        ldx #0
        lda #0
@ca:    sta $2000,x
        sta $2100,x
        sta $2200,x
        inx
        bne @ca          ; clear $2000-$22FF (768 B)

        lda #$02
        sta COLOR4
        lda #$10
        sta COLOR2
        lda #$0A
        sta COLOR1
        jsr stop_sound
        

        ; Setup VBI cursor blinker
        lda #0
        sta vbi_flag
        lda #8
        sta vbi_cnt
        ; Save old deferred VBI
        lda $0224
        sta old_vbi
        lda $0225
        sta old_vbi+1
        ; Install our VBI
        ldy #<vbi_cursor
        ldx #>vbi_cursor
        lda #7           ; deferred VBI
        jsr $E45C        ; SETVBV

        lda #1
        sta first_turn   ; first turn: clear hash

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
        sta hint_mode
        sta dream_flag
        sta dream_chain
        lda #<prm
        ldx #>prm
        ldy #prml
        jsr ps
        jsr rline_timeout
        bcc got_input
        jsr idle_chatter
got_input:
        ; Strip trailing punctuation (?!.)
@strip: ldx llen
        beq mloop
        dex
        lda iline,x
        cmp #63          ; '?'
        beq @cut
        cmp #33          ; '!'
        beq @cut
        cmp #46          ; '.'
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
        ; === Long input: first 10 + last 6 ===
        ldx #0
@cp10:  lda iline,x
        cmp #65
        bcc @s10
        cmp #91
        bcs @s10
        ora #$20
@s10:   sta ctx,x
        inx
        cpx #10
        bne @cp10
        ; Copy last 6 from iline[llen-6]
        lda llen
        sec
        sbc #6
        tay              ; Y = llen-6 (source)
@cp6:   lda iline,y
        cmp #65
        bcc @s6
        cmp #91
        bcs @s6
        ora #$20
@s6:    sta ctx,x
        iny
        inx
        cpx #16
        bne @cp6
        lda #16
        sta llen
        jmp @qd
@lenok:
        ; === Normal copy (llen <= 16) ===
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
        jmp @cpq
@qd:    lda #SEP_CHAR
        sta ctx,x
        inx
        stx ctxlen

        ; (ctx_write moved to after ctx_attend)

        ; === Context-aware hash ===
        lda first_turn
        beq @decay
        ; First turn: clear live half
        jsr ihash_clear_live
        lda #0
        sta first_turn   ; subsequent turns rebuild
        jmp @dohash
@decay: ; Full rebuild each turn
        jsr ihash_clear_live
@dohash:
        jsr hash_live
        jsr hash_frozen
        jsr build_ctx_sketch
        jsr build_ctx_query
        jsr build_frozen_nz_cache
        jsr build_frozen_base

        ; === Generate loop ===
        lda #0
        sta gencnt
        sta repchr       ; repeat counter
        lda #$FF
        sta lastch       ; no previous char
        lda #' '
        sta co
        jsr pc          ; leading space before answer

        jsr start_sound
        lda #1
        sta vbi_flag     ; enable cursor blink (once)

gen_loop:
        jsr thinking_sound
        lda #1
        sta answer_ok
        lda NMIEN
        sta nmien_save
        lda #0
        sta NMIEN

        ; === L1: full for first char, incremental for rest ===
        lda gencnt
        bne @incr_l1

        ; --- FIRST CHAR: full L1 ---
        jsr ihash_clear_live
        jsr hash_live
        jsr hash_abag
        jsr l1_full_sparse
        jmp @do_l2

@incr_l1:
        ; Incremental live-delta update over cached preact.
        jsr l1_incremental

@do_l2:

        ; Phase 2: lightweight XE context memory on top of the new 512-input
        ; frozen query anchor.
        jsr ctx_attend
        jsr ctx_write

        ; === L2: sparse output over non-zero hidbuf, then proven argmax ===
        lda #<w2_data
        sta wptr
        lda #>w2_data
        sta wptr+1

        ; 3-phase bias: B2S(0-2), B2M(3-7), B2(8+)
        lda gencnt
        cmp #8
        bcs @use_b2
        cmp #3
        bcs @use_b2m
        lda #<b2s_data
        sta bptr
        lda #>b2s_data
        sta bptr+1
        jmp @b2done
@use_b2m:
        lda #<b2m_data
        sta bptr
        lda #>b2m_data
        sta bptr+1
        jmp @b2done
@use_b2:
        lda #<b2_data
        sta bptr
        lda #>b2_data
        sta bptr+1
@b2done:
        lda #<hidbuf
        sta aptr_b
        lda #>hidbuf
        sta aptr_b+1
        lda #N_OUT
        sta ocnt
        jsr l2_argmax_sparse

        ; === Confidence check: first char only ===
        ; margin < 3 -> JUST ASK (prevents garbage start)
        ; No mid-gen check (was cutting valid answers on real HW)
        ; MAX_GEN is intentionally a bit looser on XE; repeat detection and
        ; EOL shaping still keep runaway text in check.
        lda gencnt
        bne @conf_ok
        sec
        lda blo
        sbc slo
        sta tmp
        lda bhi
        sbc shi
        bne @conf_ok        ; high byte != 0 = large margin
        lda tmp
        cmp #3              ; first char threshold (lowered: trained min=2)
        bcs @conf_ok
        lda nmien_save
        sta NMIEN
        jmp gen_unsure      ; -> prints JUST ASK
@conf_ok:
        ; === Check EOL with margin guard ===
        lda besti
        cmp #EOL_IDX
        bne @not_eol
        ; EOL is best. Check margin (best - second).
        ; If margin < 5 AND we're still relatively early: use second instead
        lda gencnt
        cmp #20
        bcs @eol_ok       ; late enough, accept EOL
        ; Compare margin: blo:bhi - slo:shi
        sec
        lda blo
        sbc slo
        sta tmp
        lda bhi
        sbc shi            ; 16-bit subtract
        ; If high byte nonzero (positive), margin >= 256: accept EOL
        bne @eol_ok
        ; High byte 0: check low byte
        lda tmp
        cmp #5
        bcs @eol_ok        ; margin >= 5: accept EOL
        ; Margin < 5: suppress EOL, use second best
        lda second
        sta besti
@eol_ok:
        lda besti
        cmp #EOL_IDX
        bne @not_eol
        lda nmien_save
        sta NMIEN
        jmp gen_done
@not_eol:
        lda nmien_save
        sta NMIEN

        ; === Output character ===
        ldx besti
        lda charset,x
        sta co

        ; === Repeat detection (fallback for unknown) ===
        cmp lastch
        bne @newch
        inc repchr
        lda repchr
        cmp #3           ; 3 same chars in a row = garbage
        bcc @printch_ok
        jmp gen_fallback
@printch_ok:
        jmp @printch
@newch: sta lastch
        lda #1
        sta repchr
@printch:
        jsr stop_sound
        lda dream_flag
        beq @print_normal
        lda co
        ora #$80
        sta co
        lda dream_color
        clc
        adc #$13
        sta dream_color
        sta COLOR4
        eor #$84
        sta COLOR2
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
        jsr reset_brand_colors
        lda #EOL
        sta co
        jsr pc
        jmp mloop
@print_normal:
        jsr pc
@after_print:

        ; === Append to context (lowercase) ===
        lda co           ; P2: reuse co (no re-read from charset)
        and #$7F         ; dream mode prints inverse, keep ctx plain ASCII
        cmp #65          ; 'A'
        bcc @nolow
        cmp #91          ; 'Z'+1
        bcs @nolow
        ora #$20         ; to lowercase
@nolow: ldx ctxlen
        sta ctx,x
        inx
        stx ctxlen

        ; JAMXE v1 rebuilds live features from ctx every token.
        ; Keep post-print path side-effect free.
        inc gencnt
        lda gencnt
        cmp #MAX_GEN
        bcs @gen_done_now
        jmp gen_loop
@gen_done_now:
        jmp gen_done

gen_unsure:
        lda hint_mode
        beq @nohint_unsure
        jmp gen_done_hint
@nohint_unsure:
        jsr stop_sound
        lda #0
        sta answer_ok
        lda #0
        sta vbi_flag
        lda $14
        and #7
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
        lda hint_mode
        beq @nohint_fallback
        jmp gen_done_hint
@nohint_fallback:
        jsr stop_sound
        lda #0
        sta answer_ok
        ; Erase printed garbage (repchr-1 chars were printed)
        ldx repchr
        dex
@bksp:  lda #$7E        ; backspace
        sta co
        txa
        pha
        jsr pc
        pla
        tax
        dex
        bne @bksp
        ; New line + leading space
        lda #EOL
        sta co
        jsr pc
        lda #$20
        sta co
        jsr pc
        ; Pick 1 of 3 fallback messages via RTCLOK
        lda $14
        and #$03
        cmp #3
        bcc @fbpick
        lda #0
@fbpick:
        pha              ; save index 0/1/2
        asl
        tax
        lda fb_ptrs,x    ; word-indexed pointer
        sta aptr
        lda fb_ptrs+1,x
        sta aptr+1
        pla              ; restore index 0/1/2
        tax
        lda fb_lens,x    ; byte-indexed length
        tay
        jsr ps_inv

gen_done:
        jsr stop_sound
        lda #0
        sta vbi_flag     ; disable cursor blink
        ; Restore screen byte in case it is inverted
        ldy #0
        lda ($5E),y      ; OLDADR
        and #$7F         ; clear inverse bit
        sta ($5E),y
        lda #EOL
        sta co
        jsr pc

        lda dream_flag
        bne dream_is_active
        jmp not_dreaming
dream_is_active:
        jsr copy_answer_to_iline
        bcc gen_done_dream
        inc dream_chain
        lda dream_chain
        cmp #3
        bcs gen_done_dream
        ldx #50
@dpause:
        lda dream_color
        clc
        adc #$07
        sta dream_color
        sta COLOR4
        eor #$84
        sta COLOR2
        lda $14
@dpw:   cmp $14
        beq @dpw
        lda CH
        cmp #$FF
        bne gen_done_dream
        dex
        bne @dpause
        lda #'.'+$80
        sta co
        jsr pc
        jsr pc
        jsr pc
        lda #' '
        sta co
        jsr pc
        jmp got_input
gen_done_dream:
        lda #0
        sta dream_flag
        jsr reset_brand_colors
        jmp mloop
not_dreaming:
        ; === Neural hint: continue the current answer (rare, subtle) ===
        lda hint_mode
        bne hint_skip         ; no recursion
        lda answer_ok
        beq hint_skip         ; skip after fallback/unsure
        lda gencnt
        cmp #3
        bcc hint_skip         ; skip very short answers
        cmp #7
        bcs hint_skip         ; only expand compact short answers
        lda RANDOM
        and #$07
        bne hint_skip         ; ~12.5% chance
        ; Keep the original query anchor and extend the current answer.
        ; This is much more stable on JAM XE than treating the answer
        ; as a brand-new prompt.
        ldx ctxlen
        cpx #127
        bcs hint_skip
        lda #' '
        sta ctx,x
        inx
        stx ctxlen
        lda #1
        sta hint_mode
        lda #0
        sta gencnt
        sta repchr
        lda #$FF
        sta lastch
        lda #' '
        sta co
        jsr pc
        jsr start_sound
        jmp gen_loop
gen_done_hint:
        jsr stop_sound
hint_skip:
        lda #0
        sta hint_mode

        ; === Proactive suggestion (only after short, good answers) ===
        lda answer_ok
        beq @no_sug          ; skip after fallback/unsure
        lda gencnt
        cmp #7               ; only after short answers (<=6 chars)
        bcs @no_sug          ; skip after quiz questions, long facts
        lda $14              ; RTCLOK
        and #7               ; 0-7
        cmp #3               ; 0,1,2 = suggest (37%)
        bcs @no_sug
        ; Pick suggestion index, save on stack (ZP unsafe from CIOV)
        lda $14
        lsr
        lsr
        lsr
        and #7               ; 8 suggestions
        pha                  ; save index on stack

        ; Print prefix first (CIOV trashes ZP)
        lda #$20
        sta co
        jsr pc               ; space
        jsr pc               ; space

        ; NOW set up aptr (after CIOV calls, from stack)
        pla                  ; restore index
        pha                  ; keep a copy
        asl
        tax
        lda sug_ptrs,x
        sta aptr
        lda sug_ptrs+1,x
        sta aptr+1
        pla                  ; restore index again
        tax
        lda sug_lens,x
        tay
        ; Print suggestion in inverse
        jsr ps_inv
        lda #EOL
        sta co
        jsr pc
@no_sug:
        jmp mloop

copy_answer_to_iline:
        ldx #0
@cas_sep:
        lda ctx,x
        cmp #SEP_CHAR
        beq @cas_found
        inx
        cpx ctxlen
        bne @cas_sep
        clc
        rts
@cas_found:
        inx
        ldy #0
@cas_copy:
        cpx ctxlen
        beq @cas_done
        lda ctx,x
        sta iline,y
        inx
        iny
        cpy #MAX_INPUT
        bcc @cas_copy
@cas_done:
        lda #0
        sta iline,y
        sty llen
        cpy #2
        bcc @cas_fail
        sec
        rts
@cas_fail:
        clc
        rts

; =====================================================
; 512-input XE hash
; live  [0..255]   = trigram + bag + answer suffix
; frozen[256..511] = query anchor blocks
; =====================================================
ihash_clear_live:
        ldx #0
        lda #0
@clr:   sta ihash,x
        inx
        bne @clr
        rts

hash_live:
        ; Hash ctx trigrams INTO existing ihash[0..191]
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
        ; live bag -> ihash[192..223]
        ldx #0
@bag:   cpx ctxlen
        beq @bdone
        lda ctx,x
        and #$1F
        tay
        lda ihash+192,y
        cmp #255
        beq @bsat
        clc
        adc #1
        sta ihash+192,y
@bsat:  inx
        jmp @bag
@bdone:
        ; live suffix -> ihash[224..255]
        lda gencnt
        beq @sfx_d
        ldx ctxlen
        dex
        lda ctx,x
        sta tmp
        and #7
        clc
        adc #32
        tax
        inc ihash+192,x
        lda gencnt
        and #7
        clc
        adc #56
        tax
        inc ihash+192,x
        lda gencnt
        cmp #2
        bcc @sfx_d
        ldx ctxlen
        dex
        dex
        lda ctx,x
        and #7
        clc
        adc #40
        tax
        inc ihash+192,x
        ldx ctxlen
        dex
        dex
        lda tmp
        sec
        sbc ctx,x
        and #7
        clc
        adc #48
        tax
        inc ihash+192,x
@sfx_d: rts

hash_frozen:
        ; Clear frozen half ihash[256..511]
        ldx #0
        lda #0
@fcl:   sta ihash+256,x
        inx
        bne @fcl

        ; Find query separator position.
        ldx #0
@fs:    lda ctx,x
        cmp #SEP_CHAR
        beq @fsep
        inx
        cpx ctxlen
        bne @fs
        rts
@fsep:  stx mag

        ; qtri128 -> ihash[256..383]
        lda mag
        cmp #3
        bcc @qt_done
        ldx #0
@qt:    txa
        clc
        adc #2
        cmp mag
        bcs @qt_done
        lda ctx,x
        and #$7F
        asl
        asl
        asl
        asl
        asl
        sta acc_lo
        lda ctx,x
        and #$7F
        sta sh_lo
        sec
        lda acc_lo
        sbc sh_lo
        sta acc_lo
        lda ctx+1,x
        and #$7F
        sta sh_lo
        asl
        asl
        asl
        sec
        sbc sh_lo
        clc
        adc acc_lo
        clc
        adc ctx+2,x
        and #$7F
        stx tmp
        tax
        lda ihash+256,x
        cmp #255
        beq @qtsat
        inc ihash+256,x
@qtsat: ldx tmp
        inx
        jmp @qt
@qt_done:

        ; qbag32 -> ihash[384..415]
        ldx #0
@qb:    cpx mag
        beq @qb_done
        lda ctx,x
        and #$1F
        stx tmp
        tax
        lda ihash+384,x
        cmp #255
        beq @qbsat
        inc ihash+384,x
@qbsat: ldx tmp
        inx
        jmp @qb
@qb_done:

        ; qsfx32 -> ihash[448..479]
        lda mag
        beq @qs_done
        tax
        dex
        stx sh_lo
        lda ctx,x
        sta sh_hi
        and #7
        tax
        inc ihash+448,x

        ldx sh_lo
        ldy #0
@wl:    lda ctx,x
        cmp #$20
        beq @wl_d
        iny
        dex
        bpl @wl
@wl_d:  tya
        and #7
        tax
        inc ihash+472,x

        lda mag
        cmp #2
        bcc @qs_done
        ldx sh_lo
        dex
        lda ctx,x
        sta tmp
        and #7
        tax
        inc ihash+456,x
        lda sh_hi
        sec
        sbc tmp
        and #7
        tax
        inc ihash+464,x
@qs_done:

        ; qact32 -> ihash[480..511]
        ; [480..487] first-word act:
        ; who/what/why/how/where/when/is-can-do/other
        ; [488..495] query length & 7
        ; [496..503] word count bucket min(words,7)
        ; [504] '?' present
        ; [505] any digit present
        lda mag
        and #7
        tax
        inc ihash+488,x

        ; first word length in tmp
        ldx #0
@fwlen: cpx mag
        beq @fwdone
        lda ctx,x
        cmp #$20
        beq @fwdone
        inx
        jmp @fwlen
@fwdone:
        stx tmp

        lda tmp
        beq @qa_words
        jsr qact_head_bucket
        tax
        inc ihash+480,x

@qa_words:
        ; word count bucket: min(len(query.split()), 7)
        ldx #0
        ldy #0
        lda #0
        sta sh_lo          ; in_word flag
@wc_loop:
        cpx mag
        beq @wc_done
        lda ctx,x
        cmp #$20
        beq @wc_space
        lda sh_lo
        bne @wc_next
        iny
        lda #1
        sta sh_lo
        jmp @wc_next
@wc_space:
        lda #0
        sta sh_lo
@wc_next:
        inx
        jmp @wc_loop
@wc_done:
        tya
        cmp #8
        bcc @wc_cap
        lda #7
@wc_cap:
        tax
        inc ihash+496,x

        ; flags: ? present, any digit present
        ldx #0
@qaf:   cpx mag
        beq @qa_done
        lda ctx,x
        cmp #$3F
        bne @qaf_d
        lda ihash+504
        bne @qaf_d
        inc ihash+504
@qaf_d:
        lda ctx,x
        cmp #'0'
        bcc @qaf_n
        cmp #'9'+1
        bcs @qaf_n
        lda ihash+505
        bne @qaf_n
        inc ihash+505
@qaf_n:
        inx
        jmp @qaf
@qa_done:
        rts

; =====================================================
; Build tiny 4-d query sketch for XE context memory.
; Encodes query form from frozen one-hot groups into thash[0..3].
; =====================================================
build_ctx_sketch:
        ; qact bucket [480..487]
        ldx #0
@bcs0:  lda ihash+480,x
        bne @bcs0f
        inx
        cpx #8
        bne @bcs0
        lda #7
        bne @bcs0s
@bcs0f: txa
@bcs0s: sta thash

        ; qlen bucket [488..495]
        ldx #0
@bcs1:  lda ihash+488,x
        bne @bcs1f
        inx
        cpx #8
        bne @bcs1
        lda #0
        beq @bcs1s
@bcs1f: txa
@bcs1s: sta thash+1

        ; word-count bucket [496..503]
        ldx #0
@bcs2:  lda ihash+496,x
        bne @bcs2f
        inx
        cpx #8
        bne @bcs2
        lda #0
        beq @bcs2s
@bcs2f: txa
@bcs2s: sta thash+2

        ; last-query-char bucket [448..455]
        ldx #0
@bcs3:  lda ihash+448,x
        bne @bcs3f
        inx
        cpx #8
        bne @bcs3
        lda #0
        beq @bcs3s
@bcs3f: txa
@bcs3s: sta thash+3
        rts

build_ctx_query:
        ; D_J rotation over the frozen query sketch.
        ; q[0]=-x[2]+x[3], q[1]=-x[2], q[2]=x[0]-x[2], q[3]=x[1]-x[2]
        lda thash+2
        sta tmp
        lda thash+3
        sec
        sbc tmp
        sta ctx_query
        lda #0
        sec
        sbc tmp
        sta ctx_query+1
        lda thash
        sec
        sbc tmp
        sta ctx_query+2
        lda thash+1
        sec
        sbc tmp
        sta ctx_query+3
        rts

; =====================================================
; qact head-word bucket
; Input: tmp = first word length, ctx[0..] = lowercase query
; Output: A = bucket 0..7
;   0 who, 1 what, 2 why, 3 how, 4 where, 5 when, 6 aux, 7 other
; =====================================================
qact_head_bucket:
        lda tmp
        cmp #2
        beq @qh2
        cmp #3
        beq @qh3
        cmp #4
        bne @qh_chk5
        jmp @qh4
@qh_chk5:
        cmp #5
        bne @qh_default
        jmp @qh5
@qh_default:
        lda #7
        rts

@qh2:   lda ctx
        cmp #'i'
        bne @qh2_do
        lda ctx+1
        cmp #'s'
        bne @qh2_do
        lda #6
        rts
@qh2_do:
        lda ctx
        cmp #'d'
        bne @qh2_other
        lda ctx+1
        cmp #'o'
        bne @qh2_other
        lda #6
        rts
@qh2_other:
        jmp @qh_other

@qh3:   lda ctx
        cmp #'w'
        bne @qh3_how
        lda ctx+1
        cmp #'h'
        bne @qh3_how
        lda ctx+2
        cmp #'o'
        bne @qh3_why
        lda #0
        rts
@qh3_why:
        cmp #'y'
        bne @qh3_how
        lda #2
        rts
@qh3_how:
        lda ctx
        cmp #'h'
        bne @qh3_can
        lda ctx+1
        cmp #'o'
        bne @qh3_can
        lda ctx+2
        cmp #'w'
        bne @qh3_can
        lda #3
        rts
@qh3_can:
        lda ctx
        cmp #'c'
        bne @qh3_are
        lda ctx+1
        cmp #'a'
        bne @qh3_are
        lda ctx+2
        cmp #'n'
        bne @qh3_are
        lda #6
        rts
@qh3_are:
        lda ctx
        cmp #'a'
        bne @qh3_other
        lda ctx+1
        cmp #'r'
        bne @qh3_other
        lda ctx+2
        cmp #'e'
        bne @qh3_other
        lda #6
        rts
@qh3_other:
        jmp @qh_other

@qh4:   lda ctx
        cmp #'w'
        bne @qh4_does
        lda ctx+1
        cmp #'h'
        bne @qh4_does
        lda ctx+2
        cmp #'a'
        bne @qh4_when
        lda ctx+3
        cmp #'t'
        bne @qh4_when
        lda #1
        rts
@qh4_when:
        lda ctx+2
        cmp #'e'
        bne @qh4_does
        lda ctx+3
        cmp #'n'
        bne @qh4_does
        lda #5
        rts
@qh4_does:
        lda ctx
        cmp #'d'
        bne @qh4_will
        lda ctx+1
        cmp #'o'
        bne @qh4_will
        lda ctx+2
        cmp #'e'
        bne @qh4_will
        lda ctx+3
        cmp #'s'
        bne @qh4_will
        lda #6
        rts
@qh4_will:
        lda ctx
        cmp #'w'
        bne @qh4_other
        lda ctx+1
        cmp #'i'
        bne @qh4_other
        lda ctx+2
        cmp #'l'
        bne @qh4_other
        lda ctx+3
        cmp #'l'
        bne @qh4_other
        lda #6
        rts
@qh4_other:
        jmp @qh_other

@qh5:   lda ctx
        cmp #'w'
        bne @qh5_could
        lda ctx+1
        cmp #'h'
        bne @qh5_would
        lda ctx+2
        cmp #'e'
        bne @qh5_would
        lda ctx+3
        cmp #'r'
        bne @qh5_would
        lda ctx+4
        cmp #'e'
        bne @qh5_would
        lda #4
        rts
@qh5_would:
        lda ctx+1
        cmp #'o'
        bne @qh5_could
        lda ctx+2
        cmp #'u'
        bne @qh5_could
        lda ctx+3
        cmp #'l'
        bne @qh5_could
        lda ctx+4
        cmp #'d'
        bne @qh5_could
        lda #6
        rts
@qh5_could:
        lda ctx
        cmp #'c'
        bne @qh5_other
        lda ctx+1
        cmp #'o'
        bne @qh5_other
        lda ctx+2
        cmp #'u'
        bne @qh5_other
        lda ctx+3
        cmp #'l'
        bne @qh5_other
        lda ctx+4
        cmp #'d'
        bne @qh5_other
        lda #6
        rts
@qh5_other:
        jmp @qh_other

@qh_other:
        lda #7
        rts

hash_abag:
        ; answer-only bag -> ihash[416..447]
        ldx #31
        lda #0
@acl:   sta ihash+416,x
        dex
        bpl @acl
        ldx #0
@fab:   lda ctx,x
        cmp #SEP_CHAR
        beq @fab_found
        inx
        cpx ctxlen
        bne @fab
        rts
@fab_found:
        inx
@ab:    cpx ctxlen
        beq @ab_done
        lda ctx,x
        and #$1F
        stx tmp
        tax
        lda ihash+416,x
        cmp #255
        beq @absat
        inc ihash+416,x
@absat: ldx tmp
        inx
        jmp @ab
@ab_done:
        rts

; === Hash one trigram: tc0, tc1, tc2 -> ihash[h]++ ===
tri_one:
        ; h = (tc0*31 + tc1*7 + tc2) mod 192 (16-bit)
        ; tc0 * 32 - tc0 (16-bit via ASL mem/ROL mem)
        lda tc0
        sta acc_lo
        lda #0
        sta acc_hi
        asl acc_lo
        rol acc_hi
        asl acc_lo
        rol acc_hi
        asl acc_lo
        rol acc_hi
        asl acc_lo
        rol acc_hi
        asl acc_lo
        rol acc_hi
        sec
        lda acc_lo
        sbc tc0
        sta acc_lo
        lda acc_hi
        sbc #0
        sta acc_hi
        ; + tc1 * 8 - tc1 (16-bit via ASL mem/ROL mem)
        lda tc1
        sta tmp
        lda #0
        sta wbyte
        asl tmp
        rol wbyte
        asl tmp
        rol wbyte
        asl tmp
        rol wbyte
        sec
        lda tmp
        sbc tc1
        sta tmp
        lda wbyte
        sbc #0
        sta wbyte
        clc
        lda acc_lo
        adc tmp
        sta acc_lo
        lda acc_hi
        adc wbyte
        sta acc_hi
        ; + tc2
        clc
        lda acc_lo
        adc tc2
        sta acc_lo
        lda acc_hi
        adc #0
        sta acc_hi
        ; mod 192: reduce lo, then add 64 per hi (reduce each step)
        lda acc_lo
        cmp #192
        bcc @lo_ok
        sbc #192
@lo_ok: ldx acc_hi
        beq @done
@add64: clc
        adc #64
        cmp #192
        bcc @a64ok
        sbc #192
@a64ok: dex
        bne @add64
@done:  sta last_bucket
        tax
        lda ihash,x
        cmp #255
        beq @sat
        inc ihash,x
@sat:   rts
; =====================================================
; L2: sparse output fused with argmax.
; Preserves best/second semantics from amax45, but avoids obuf writes and
; the second argmax pass.
; =====================================================
l2_argmax_sparse:
        ; Row 0 seeds both best and second, same as old amax45.
        jsr cneuron_sparse_w2
        ldy #0
        lda (bptr),y
        ldx #0
        cmp #$80
        bcc @s0bp
        ldx #$FF
@s0bp:  clc
        adc acc_lo
        sta blo
        sta slo
        txa
        adc acc_hi
        sta bhi
        sta shi
        lda #0
        sta besti
        sta second
        sta outi
        inc bptr
        bne @s0nb
        inc bptr+1
@s0nb:  inc wptr+1       ; next W2 row
        inc outi
@l2n:   jsr cneuron_sparse_w2
        ldy #0
        lda (bptr),y
        ldy #0
        cmp #$80
        bcc @l2bp
        dey               ; Y = $FF sign extension for negative bias
@l2bp:  clc
        adc acc_lo
        sta acc_lo
        tya
        adc acc_hi
        sta acc_hi

        ; Algorithmic EOL shaping on the candidate EOL row.
        lda outi
        cmp #EOL_IDX
        bne @l2cmp
        lda gencnt
        cmp #3
        bcs @l2e_mid
        ; pos < 3: strongly suppress EOL
        sec
        lda acc_lo
        sbc #40
        sta acc_lo
        lda acc_hi
        sbc #0
        sta acc_hi
        jmp @l2cmp
@l2e_mid:
        cmp #8
        bcs @l2e_late
        ; pos 3-7: still suppress, but more gently
        sec
        lda acc_lo
        sbc #15
        sta acc_lo
        lda acc_hi
        sbc #0
        sta acc_hi
        jmp @l2cmp
@l2e_late:
        cmp #15
        bcc @l2cmp
        ; pos 15+: progressive EOL boost, but gentler than before
        sec
        sbc #15
        asl
        asl
        clc
        adc #12
        clc
        adc acc_lo
        sta acc_lo
        lda #0
        adc acc_hi
        sta acc_hi

@l2cmp:
        ; Compare current acc vs best (signed 16-bit).
        sec
        lda acc_lo
        sbc blo
        lda acc_hi
        sbc bhi
        bvc @l2nv
        eor #$80
@l2nv:  bmi @l2_not_best
        lda besti
        sta second
        lda blo
        sta slo
        lda bhi
        sta shi
        lda outi
        sta besti
        lda acc_lo
        sta blo
        lda acc_hi
        sta bhi
        jmp @l2next
@l2_not_best:
        sec
        lda acc_lo
        sbc slo
        lda acc_hi
        sbc shi
        bvc @l2nv2
        eor #$80
@l2nv2: bmi @l2next
        lda outi
        sta second
        lda acc_lo
        sta slo
        lda acc_hi
        sta shi
@l2next:
        inc bptr
        bne @l2nb
        inc bptr+1
@l2nb:  inc wptr+1
        inc outi
        lda outi
        cmp #N_OUT
        beq @l2done
        jmp @l2n
@l2done:
        rts

; =====================================================
; Shift-and-add multiply: mag * act -> prod (16-bit)
; =====================================================
mul:
        sta mag
        lda #0
        sta prod_lo
        sta prod_hi
        lda act
        sta sh_lo
        lda #0
        sta sh_hi
        lsr mag
        bcc @0
        clc
        lda prod_lo
        adc sh_lo
        sta prod_lo
        lda prod_hi
        adc sh_hi
        sta prod_hi
@0:     asl sh_lo
        rol sh_hi
        lsr mag
        bcc @1
        clc
        lda prod_lo
        adc sh_lo
        sta prod_lo
        lda prod_hi
        adc sh_hi
        sta prod_hi
@1:     asl sh_lo
        rol sh_hi
        lsr mag
        bcc @2
        clc
        lda prod_lo
        adc sh_lo
        sta prod_lo
        lda prod_hi
        adc sh_hi
        sta prod_hi
@2:     asl sh_lo
        rol sh_hi
        lsr mag
        bcc @3
        clc
        lda prod_lo
        adc sh_lo
        sta prod_lo
        lda prod_hi
        adc sh_hi
        sta prod_hi
@3:     rts

; =====================================================
; Argmax over 45 values (single loop, fits in page)
; =====================================================
amax45:
        ; Find best AND second-best indices
        lda obuf
        sta blo
        sta slo
        lda obuf+1
        sta bhi
        sta shi
        lda #0
        sta besti
        sta second
        ldx #1
@c:     txa
        asl
        tay
        ; Compare obuf[x] vs best (signed 16-bit)
        sec
        lda obuf,y
        sbc blo
        lda obuf+1,y
        sbc bhi
        bvc @nv
        eor #$80
@nv:    bmi @not_best
        ; New best: old best -> second
        lda besti
        sta second
        lda blo
        sta slo
        lda bhi
        sta shi
        ; Update best
        stx besti
        lda obuf,y
        sta blo
        lda obuf+1,y
        sta bhi
        jmp @next
@not_best:
        ; Check if obuf[x] > second
        sec
        lda obuf,y
        sbc slo
        lda obuf+1,y
        sbc shi
        bvc @nv2
        eor #$80
@nv2:   bmi @next
        ; New second
        stx second
        lda obuf,y
        sta slo
        lda obuf+1,y
        sta shi
@next:  inx
        cpx #N_OUT
        bne @c
        rts

; =====================================================
; I/O routines (from JAM)
; =====================================================
reset_brand_colors:
        lda #$02
        sta COLOR4
        lda #$10
        sta COLOR2
        lda #$0A
        sta COLOR1
        rts

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
        adc #<1500
        sta tmp
        lda wbyte
        adc #>1500
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

idle_chatter:
        lda RANDOM
        and #15
        pha
        asl
        tax
        lda drm_ptrs,x
        sta aptr
        lda drm_ptrs+1,x
        sta aptr+1
        pla
        tax
        lda drm_lens,x
        sta llen
        ldy #0
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
        lda RANDOM
        sta dream_color
        lda #'.'+$80
        sta co
        jsr pc
        jsr pc
        jsr pc
        lda #' '
        sta co
        jsr pc
        clc
        rts

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
        lda #0
        sta $02F0       ; CRSINH=0: cursor blinks after every output
        rts

ps_inv:
        ; Print Y bytes from (aptr) in inverse video
        sty inv_len
        ldy #0
@inv:   lda (aptr),y
        ora #$80         ; set inverse bit
        sta co
        lda aptr         ; CIOV trashes OS zero page, preserve pointer
        pha
        lda aptr+1
        pha
        tya
        pha
        jsr pc
        pla
        tay
        pla
        sta aptr+1
        pla
        sta aptr
        iny
        cpy inv_len
        bne @inv
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

start_sound:
        lda dream_flag
        bne stop_sound
        lda #0
        sta snd_ctr
        sta AUDCTL
        lda #$A1
        sta AUDC1
        lda #$60
        sta AUDF1
        rts

thinking_sound:
        lda dream_flag
        bne @snd_mute
        lda snd_ctr
        lsr
        and #$07
        clc
        adc #$58
        sta AUDF1
        inc snd_ctr
@snd_mute:
        rts

stop_sound:
        lda #0
        sta AUDC1
        sta AUDF1
        rts


; =====================================================
; INCREMENTAL L1 over cached preact (bank-major)
; Collects all live deltas into dirty table, then applies
; them in a single sweep across all 4 banks.
; =====================================================
.segment "HICODE"

; --- Dirty table helpers ---
; Input: tmp = byte offset in W1 row (0-127), nibble_sel = nibble position (0-3)
note_dirty_add:
        ldy dirty_count
        cpy #16
        bcs @nda_done
        lda tmp
        sta dirty_off,y
        lda nibble_sel
        sta dirty_nib,y
        lda #0
        sta dirty_sgn,y
        inc dirty_count
@nda_done:
        rts

note_dirty_sub:
        ldy dirty_count
        cpy #16
        bcs @nds_done
        lda tmp
        sta dirty_off,y
        lda nibble_sel
        sta dirty_nib,y
        lda #1
        sta dirty_sgn,y
        inc dirty_count
@nds_done:
        rts

l1_incremental:
        lda #0
        sta dirty_count

        ; 1. New trigram ending at the newest char.
        lda ctxlen
        cmp #3
        bcc @li_no_tri
        ldx ctxlen
        dex
        dex
        dex
        lda ctx,x
        sta tc0
        lda ctx+1,x
        sta tc1
        lda ctx+2,x
        sta tc2
        jsr tri_one
        lda last_bucket
        lsr
        lsr
        sta tmp
        lda last_bucket
        and #3
        sta nibble_sel
        jsr note_dirty_add
@li_no_tri:

        ; 2. New live bag bucket (ihash[192..223]).
        ldx ctxlen
        dex
        lda ctx,x
        and #$1F
        sta act
        lsr
        lsr
        clc
        adc #48            ; 192 / 4
        sta tmp
        lda act
        and #3
        sta nibble_sel
        jsr note_dirty_add

        ; 3. Remove old suffix features (gencnt-1).
        lda gencnt
        cmp #2
        bcs @li_has_old_sfx
        jmp @li_no_old_sfx
@li_has_old_sfx:
        ; old last char = ctx[len-2]
        ldx ctxlen
        dex
        dex
        lda ctx,x
        sta act
        and #7
        lsr
        lsr
        clc
        adc #56            ; 224 / 4
        sta tmp
        lda act
        and #3
        sta nibble_sel
        jsr note_dirty_sub
        ; old length bucket = 248 + ((gencnt-1) & 7)
        lda gencnt
        sec
        sbc #1
        and #7
        sta act
        lsr
        lsr
        clc
        adc #62            ; 248 / 4
        sta tmp
        lda act
        and #3
        sta nibble_sel
        jsr note_dirty_sub
        ; old prev+delta only when gencnt >= 3
        lda gencnt
        cmp #3
        bcc @li_no_old_sfx
        ; old prev char = ctx[len-3]
        ldx ctxlen
        dex
        dex
        dex
        lda ctx,x
        sta act
        and #7
        lsr
        lsr
        clc
        adc #58            ; 232 / 4
        sta tmp
        lda act
        and #3
        sta nibble_sel
        jsr note_dirty_sub
        ; old delta = (ctx[len-2] - ctx[len-3]) & 7
        ldx ctxlen
        dex
        dex
        lda ctx,x
        sta tc0
        dex
        lda tc0
        sec
        sbc ctx,x
        and #7
        sta act
        lsr
        lsr
        clc
        adc #60            ; 240 / 4
        sta tmp
        lda act
        and #3
        sta nibble_sel
        jsr note_dirty_sub
@li_no_old_sfx:

        ; 4. Add current suffix features for gencnt.
        ldx ctxlen
        dex
        lda ctx,x
        sta act
        and #7
        lsr
        lsr
        clc
        adc #56            ; 224 / 4
        sta tmp
        lda act
        and #3
        sta nibble_sel
        jsr note_dirty_add
        ; new length bucket
        lda gencnt
        and #7
        sta act
        lsr
        lsr
        clc
        adc #62            ; 248 / 4
        sta tmp
        lda act
        and #3
        sta nibble_sel
        jsr note_dirty_add
        ; new prev+delta only when gencnt >= 2
        lda gencnt
        cmp #2
        bcc @li_no_new_sfx2
        ldx ctxlen
        dex
        dex
        lda ctx,x
        sta act
        and #7
        lsr
        lsr
        clc
        adc #58            ; 232 / 4
        sta tmp
        lda act
        and #3
        sta nibble_sel
        jsr note_dirty_add
        ; new delta = (ctx[len-1] - ctx[len-2]) & 7
        ldx ctxlen
        dex
        lda ctx,x
        sta tc0
        dex
        lda tc0
        sec
        sbc ctx,x
        and #7
        sta act
        lsr
        lsr
        clc
        adc #60            ; 240 / 4
        sta tmp
        lda act
        and #3
        sta nibble_sel
        jsr note_dirty_add
@li_no_new_sfx2:

        ; 5. Answer-only bag bucket (ihash[416..447]).
        ldx ctxlen
        dex
        lda ctx,x
        and #$1F
        sta act
        lsr
        lsr
        clc
        adc #104           ; 416 / 4
        sta tmp
        lda act
        and #3
        sta nibble_sel
        jsr note_dirty_add

        ; === Normalize: cancel +/- pairs hitting same column ===
        jsr normalize_dirty
        ; === Bank-major sweep: apply all deltas in one pass ===
        jsr l1_apply_all_deltas
        jmp relu_build_hid_sparse

; =====================================================
; Normalize dirty table: cancel +/- pairs on same column.
; Marks cancelled entries by setting dirty_off = $FF.
; Then compacts the table removing $FF entries.
; =====================================================
normalize_dirty:
        lda dirty_count
        cmp #2
        bcc @nd_done         ; 0 or 1 entries, nothing to cancel
        ldx #0
@nd_i:  cpx dirty_count
        bcs @nd_compact
        lda dirty_off,x
        cmp #$FF
        beq @nd_inext        ; already cancelled
        sta tmp              ; tmp = off[i]
        lda dirty_nib,x
        sta nibble_sel       ; nibble_sel = nib[i]
        lda dirty_sgn,x
        sta ninh             ; ninh = sgn[i]
        ; Search for opposite-sign match in entries after i
        txa
        tay
        iny
@nd_j:  cpy dirty_count
        bcs @nd_inext
        lda dirty_off,y
        cmp #$FF
        beq @nd_jnext
        cmp tmp
        bne @nd_jnext
        lda dirty_nib,y
        cmp nibble_sel
        bne @nd_jnext
        lda dirty_sgn,y
        cmp ninh
        beq @nd_jnext        ; same sign = not a cancel pair
        ; Found cancel pair: mark both as $FF
        lda #$FF
        sta dirty_off,x
        sta dirty_off,y
        jmp @nd_inext        ; i is cancelled, move on
@nd_jnext:
        iny
        jmp @nd_j
@nd_inext:
        inx
        jmp @nd_i
@nd_compact:
        ; Compact: remove $FF entries by shifting remaining ones down
        ldx #0               ; read index
        ldy #0               ; write index
@nd_cp: cpx dirty_count
        bcs @nd_cp_done
        lda dirty_off,x
        cmp #$FF
        beq @nd_cp_skip
        ; Copy entry x to position y
        sta dirty_off,y
        lda dirty_nib,x
        sta dirty_nib,y
        lda dirty_sgn,x
        sta dirty_sgn,y
        iny
@nd_cp_skip:
        inx
        jmp @nd_cp
@nd_cp_done:
        sty dirty_count
@nd_done:
        rts

; =====================================================
; Bank-major multi-delta apply
; For each bank (4), sweep all 128 rows. Per row, apply
; every dirty column. Reduces bank switches from ~52 to 4.
; =====================================================
l1_apply_all_deltas:
        lda #0
        sta cur_bank
@ad_bank:
        lda cur_bank
        asl
        asl
        ora #PORTB_CPU_EXT0
        sta PORTB
        ; Set up preact pointer for this bank
        ldx cur_bank
        lda bank_pre_lo,x
        sta aptr_b
        lda bank_pre_hi,x
        sta aptr_b+1
        ; wptr = base of bank window (advances by STRIDE per row)
        lda #<BANK_WIN
        sta wptr
        lda #>BANK_WIN
        sta wptr+1
        lda #ROWS_PER_BANK
        sta ocnt
@ad_row:
        ; For this row, iterate over all dirty columns
        ldx #0
@ad_col:
        cpx dirty_count
        bne @ad_col_go
        jmp @ad_row_done
@ad_col_go:
        stx wcnt             ; save dirty index
        ; Load weight byte at wptr + dirty_off[x]
        ldy dirty_off,x
        lda (wptr),y
        bne @ad_col_havew
        jmp @ad_col_next     ; zero byte = skip
@ad_col_havew:
        sta wbyte
        ; Extract 2-bit code at nibble position dirty_nib[x]
        ldx wcnt
        lda dirty_nib,x
        beq @ad_n0
        cmp #1
        beq @ad_n1
        cmp #2
        beq @ad_n2
        ldy wbyte
        lda twob3,y
        jmp @ad_ngot
@ad_n2: ldy wbyte
        lda twob2,y
        jmp @ad_ngot
@ad_n1: ldy wbyte
        lda twob1,y
        jmp @ad_ngot
@ad_n0: lda wbyte
        and #3
@ad_ngot:
        tay                  ; Y = 2-bit code (0-3)
        beq @ad_col_next     ; code 0 = no weight, skip
        ; Determine add or subtract based on dirty_sgn + code
        ldx wcnt
        lda dirty_sgn,x
        beq @ad_fwd
        ; subtract mode: reverse signs (code 1→+1, 2→-1, 3→+2)
        cpy #1
        beq @ad_add1
        cpy #2
        beq @ad_sub1
        jmp @ad_add2
@ad_fwd:
        ; add mode: normal signs (code 1→-1, 2→+1, 3→-2)
        cpy #1
        beq @ad_sub1
        cpy #2
        beq @ad_add1
        ; code 3 = -2
@ad_sub2:
        ldy #0
        sec
        lda (aptr_b),y
        sbc #2
        sta (aptr_b),y
        iny
        lda (aptr_b),y
        sbc #0
        sta (aptr_b),y
        jmp @ad_col_next
@ad_add2:
        ldy #0
        clc
        lda (aptr_b),y
        adc #2
        sta (aptr_b),y
        iny
        lda (aptr_b),y
        adc #0
        sta (aptr_b),y
        jmp @ad_col_next
@ad_sub1:
        ldy #0
        sec
        lda (aptr_b),y
        sbc #1
        sta (aptr_b),y
        iny
        lda (aptr_b),y
        sbc #0
        sta (aptr_b),y
        jmp @ad_col_next
@ad_add1:
        ldy #0
        clc
        lda (aptr_b),y
        adc #1
        sta (aptr_b),y
        iny
        lda (aptr_b),y
        adc #0
        sta (aptr_b),y
@ad_col_next:
        ldx wcnt
        inx
        jmp @ad_col
@ad_row_done:
        ; Advance preact pointer by 2
        clc
        lda aptr_b
        adc #2
        sta aptr_b
        bcc @ad_np
        inc aptr_b+1
@ad_np:
        ; Advance wptr by STRIDE (128)
        clc
        lda wptr
        adc #$80
        sta wptr
        lda wptr+1
        adc #0
        sta wptr+1
        dec ocnt
        beq @ad_bank_done
        jmp @ad_row
@ad_bank_done:
        lda #PORTB_MAIN
        sta PORTB
        inc cur_bank
        lda cur_bank
        cmp #N_BANKS
        beq @ad_done
        jmp @ad_bank
@ad_done:
        rts

relu_build_hid_sparse:
        lda #0
        sta frz_count
        sta tmp
        sta nibble_sel
        sta cur_bank
@rb_bank:
        ldx cur_bank
        lda bank_pre_lo,x
        sta pptr
        lda bank_pre_hi,x
        sta pptr+1
        lda bank_hid_lo,x
        sta optr
        lda bank_hid_hi,x
        sta optr+1
        lda #ROWS_PER_BANK
        sta ocnt
@rb_row:
        ldy #0
        lda (pptr),y
        sta acc_lo
        iny
        lda (pptr),y
        sta acc_hi
        lda acc_hi
        bmi @rb_z
        bne @rb_c
        lda acc_lo
        jmp @rb_s
@rb_c:  lda #255
        jmp @rb_s
@rb_z:  lda #0
@rb_s:  sta act
        beq @rb_nzskip
        ldy frz_count
        cpy #128
        bcs @rb_nzskip
        lda tmp
        sta frz_off,y
        lda nibble_sel
        sta frz_pair,y
        lda act
        sta frz_val,y
        inc frz_count
@rb_nzskip:
        ldy #0
        lda act
        sta (optr),y
        inc optr
        bne @rb_no
        inc optr+1
@rb_no:
        clc
        lda pptr
        adc #2
        sta pptr
        bcc @rb_nb
        inc pptr+1
@rb_nb:
        lda nibble_sel
        eor #1
        sta nibble_sel
        bne @rb_ix
        inc tmp
@rb_ix:
        dec ocnt
        beq @rb_bank_done
        jmp @rb_row
@rb_bank_done:
        inc cur_bank
        lda cur_bank
        cmp #N_BANKS
        beq @rb_done
        jmp @rb_bank
@rb_done:
        rts

.segment "CODE"

; =====================================================
; VBI cursor blinker (deferred VBI)
; Toggles inverse bit at cursor position every 8 frames
; =====================================================
vbi_cursor:
        lda vbi_flag
        beq @vx
        dec vbi_cnt
        bne @vx
        lda #8
        sta vbi_cnt
        ldy #0
        lda ($5E),y      ; OLDADR = screen byte at cursor
        eor #$80         ; toggle inverse bit
        sta ($5E),y
@vx:    jmp (old_vbi)    ; chain to previous deferred VBI


; =====================================================
; BUILD NON-ZERO LIST from 512-input ihash
; live   ihash[0..255]   -> byte offsets 0..63
; frozen ihash[256..511] -> byte offsets 64..127
; =====================================================
build_nz_list:
        lda #0
        sta nz_count
        tax
@bnl:   lda ihash,x
        beq @bns
        ldy nz_count
        cpy #128
        bcs @bns
        stx tmp
        txa
        lsr
        lsr
        sta nz_off,y
        lda tmp
        and #3
        sta nz_pair,y
        ldx tmp
        lda ihash,x
        sta nz_val,y
        inc nz_count
@bns:   inx
        bne @bnl
        ; Append live answer-only bag from upper half ihash[416..447].
        ; These features are dynamic per generated token, so they cannot live
        ; in the frozen query cache.
        ldx #0
@bna:   lda ihash+416,x
        beq @bnas
        ldy nz_count
        cpy #128
        bcs @bnd
        stx tmp
        txa
        lsr
        lsr
        clc
        adc #104        ; (416 / 4) + (x / 4)
        sta nz_off,y
        lda tmp
        and #3
        sta nz_pair,y
        ldx tmp
        lda ihash+416,x
        sta nz_val,y
        inc nz_count
@bnas:  inx
        cpx #32
        bne @bna
@bnd:
        rts

build_frozen_nz_cache:
        lda #0
        sta frz_count
        ldx #0
@bfc:   lda ihash+256,x
        beq @bfskip
        ldy frz_count
        cpy #64
        bcs @bfskip
        stx tmp
        txa
        lsr
        lsr
        clc
        adc #64
        sta frz_off,y
        lda tmp
        and #3
        sta frz_pair,y
        ldx tmp
        lda ihash+256,x
        sta frz_val,y
        inc frz_count
@bfskip:
        inx
        bne @bfc
        rts

; Build exact frozen+bias preact cache once per query.
; Stores 16-bit signed base sums for all 512 hidden neurons at FRZ_PRE.
build_frozen_base:
        lda #0
        sta cur_bank
@bfb_bank:
        lda cur_bank
        asl
        asl
        ora #PORTB_CPU_EXT0
        sta PORTB
        lda #<BANK_WIN
        sta wptr
        lda #>BANK_WIN
        sta wptr+1
        lda cur_bank
        clc
        adc #>FRZ_PRE
        sta optr+1
        lda #<FRZ_PRE
        sta optr
        ldx cur_bank
        lda bank_b1_lo,x
        sta bptr
        lda bank_b1_hi,x
        sta bptr+1
        lda #ROWS_PER_BANK
        sta ocnt
@bfb_row:
        jsr cneuron_2bit_frz
        ldy #0
        lda (bptr),y
        ldx #0
        cmp #$80
        bcc @bfb_bp
        ldx #$FF
@bfb_bp:
        clc
        adc acc_lo
        sta acc_lo
        txa
        adc acc_hi
        sta acc_hi
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
        bcc @bfb_no
        inc optr+1
@bfb_no:
        inc bptr
        bne @bfb_nb
        inc bptr+1
@bfb_nb:
        clc
        lda wptr
        adc #$80
        sta wptr
        lda wptr+1
        adc #0
        sta wptr+1
        dec ocnt
        bne @bfb_row
        lda #PORTB_MAIN
        sta PORTB
        inc cur_bank
        lda cur_bank
        cmp #N_BANKS
        beq @bfb_done
        jmp @bfb_bank
@bfb_done:
        rts

; Build NZ list from hidbuf (for sparse L2)
build_nz_list_hid:
        lda #0
        sta nz_count
        tax              ; X = 0..255 (first 256 bytes = hidbuf 0..255)
@bh1:   lda hidbuf,x
        beq @bhs1
        ldy nz_count
        cpy #128
        bcs @bhs1
        txa
        lsr
        sta nz_off,y     ; byte offset = X/2
        txa
        and #1
        sta nz_pair,y
        lda hidbuf,x
        sta nz_val,y
        inc nz_count
@bhs1:  inx
        bne @bh1
        ; Second half: hidbuf+256..hidbuf+511
        ldx #0
@bh2:   lda hidbuf+256,x
        beq @bhs2
        ldy nz_count
        cpy #128
        bcs @bhs2
        txa
        lsr              ; X/2
        clc
        adc #128
        sta nz_off,y
        txa
        and #1
        sta nz_pair,y
        lda hidbuf+256,x
        sta nz_val,y
        inc nz_count
@bhs2:  inx
        bne @bh2
        rts

; =====================================================
; 2-bit sparse cneuron for W1
; code 00 = skip, 01 = -1, 10 = +1, 11 = -2
; =====================================================
cneuron_2bit:
        lda #0
        sta acc_lo
        sta acc_hi
        sta wcnt
@sl:    ldx wcnt
        cpx nz_count
        beq @sd
        ldy nz_off,x
        lda (wptr),y
        beq @snxt
        sta wbyte
        ldy nz_pair,x
        beq @p0
        cpy #1
        beq @p1
        cpy #2
        beq @p2
        ldy wbyte
        lda twob3,y
        jmp @got
@p2:    ldy wbyte
        lda twob2,y
        jmp @got
@p1:    ldy wbyte
        lda twob1,y
        jmp @got
@p0:    lda wbyte
        and #3
@got:   tay
        beq @snxt
        lda nz_val,x
        sta act
        cpy #1
        beq @sub1
        cpy #2
        beq @add1
        lda act
        asl
        sta prod_lo
        lda #0
        rol
        sta prod_hi
        sec
        lda acc_lo
        sbc prod_lo
        sta acc_lo
        lda acc_hi
        sbc prod_hi
        sta acc_hi
        jmp @snxt
@sub1:  sec
        lda acc_lo
        sbc act
        sta acc_lo
        lda acc_hi
        sbc #0
        sta acc_hi
        jmp @snxt
@add1:  clc
        lda acc_lo
        adc act
        sta acc_lo
        lda acc_hi
        adc #0
        sta acc_hi
@snxt:  inc wcnt
        jmp @sl
@sd:    rts

cneuron_2bit_frz:
        lda #0
        sta acc_lo
        sta acc_hi
        sta wcnt
@sfl:   ldx wcnt
        cpx frz_count
        beq @sfd
        ldy frz_off,x
        lda (wptr),y
        beq @sfnxt
        sta wbyte
        ldy frz_pair,x
        beq @sfp0
        cpy #1
        beq @sfp1
        cpy #2
        beq @sfp2
        ldy wbyte
        lda twob3,y
        jmp @sfgot
@sfp2:  ldy wbyte
        lda twob2,y
        jmp @sfgot
@sfp1:  ldy wbyte
        lda twob1,y
        jmp @sfgot
@sfp0:  lda wbyte
        and #3
@sfgot: tay
        beq @sfnxt
        lda frz_val,x
        sta act
        cpy #1
        beq @sfsub1
        cpy #2
        beq @sfadd1
        lda act
        asl
        sta prod_lo
        lda #0
        rol
        sta prod_hi
        sec
        lda acc_lo
        sbc prod_lo
        sta acc_lo
        lda acc_hi
        sbc prod_hi
        sta acc_hi
        jmp @sfnxt
@sfsub1:
        sec
        lda acc_lo
        sbc act
        sta acc_lo
        lda acc_hi
        sbc #0
        sta acc_hi
        jmp @sfnxt
@sfadd1:
        clc
        lda acc_lo
        adc act
        sta acc_lo
        lda acc_hi
        adc #0
        sta acc_hi
@sfnxt: inc wcnt
        jmp @sfl
@sfd:   rts

; =====================================================
; L1 FULL SPARSE: banked 2-bit W1, 512 inputs, 512 hidden
; =====================================================
l1_full_sparse:
        jsr build_nz_list
        lda #0
        sta frz_count
        sta tmp
        sta nibble_sel
        lda #0
        sta cur_bank
@fs_bank:
        lda cur_bank
        asl
        asl
        ora #PORTB_CPU_EXT0
        sta PORTB
        ; wptr = BANK_WIN (start of bank)
        lda #<BANK_WIN
        sta wptr
        lda #>BANK_WIN
        sta wptr+1
        ; hidden output + cached frozen preact pointers
        lda cur_bank
        clc
        adc #>FRZ_PRE
        sta pptr+1
        lda #<FRZ_PRE
        sta pptr
        ldx cur_bank
        lda bank_pre_lo,x
        sta aptr_b
        lda bank_pre_hi,x
        sta aptr_b+1
        lda bank_hid_lo,x
        sta optr
        lda bank_hid_hi,x
        sta optr+1
        lda #ROWS_PER_BANK
        sta ocnt
@fs_row:
        jsr cneuron_2bit
        ldy #0
        clc
        lda acc_lo
        adc (pptr),y
        sta acc_lo
        iny
        lda acc_hi
        adc (pptr),y
        sta acc_hi
        ldy #0
        lda acc_lo
        sta (aptr_b),y
        iny
        lda acc_hi
        sta (aptr_b),y
        lda acc_hi
        bmi @fs_z
        bne @fs_c
        lda acc_lo
        jmp @fs_s
@fs_c:  lda #255
        jmp @fs_s
@fs_z:  lda #0
@fs_s:  sta act
        beq @fs_nzskip
        ldy frz_count
        cpy #128
        bcs @fs_nzskip
        lda tmp
        sta frz_off,y
        lda nibble_sel
        sta frz_pair,y
        lda act
        sta frz_val,y
        inc frz_count
@fs_nzskip:
        ldy #0
        lda act
        sta (optr),y
        inc optr
        bne @fs_no
        inc optr+1
@fs_no: clc
        lda aptr_b
        adc #2
        sta aptr_b
        bcc @fs_nop
        inc aptr_b+1
@fs_nop:
        clc
        lda pptr
        adc #2
        sta pptr
        bcc @fs_nb
        inc pptr+1
@fs_nb:
        clc
        lda wptr
        adc #$80
        sta wptr
        lda wptr+1
        adc #0
        sta wptr+1
        lda nibble_sel
        eor #1
        sta nibble_sel
        bne @fs_ix
        inc tmp
@fs_ix:
        dec ocnt
        beq @fs_bank_done
        jmp @fs_row
@fs_bank_done:
        lda #PORTB_MAIN
        sta PORTB
        inc cur_bank
        lda cur_bank
        cmp #N_BANKS
        beq @fs_done
        jmp @fs_bank
@fs_done:
        rts

; =====================================================
; D_J CONTEXT ATTENTION
; 32 slots, 4-dim keys/values, argmax selection
; Query sketch is built once per user query; runtime uses a ring buffer
; for writes to keep per-token overhead low.
; =====================================================

; ctx_attend: find best matching slot, add value to hidbuf before L2
ctx_attend:
        ; --- Dot product query * key for each slot ---
        ; score = sum(query[i] * key[slot*4+i]) for i=0..3
        ; Since values are small (0-3), dot product fits in 8 bits signed
        lda #0
        sta ctx_best      ; best slot = 0
        lda #$80          ; worst possible score (-128)
        sta ctx_score

        ldx #0            ; slot counter
@at_slot:
        ; Compute dot product for slot X
        ; key base = ctx_key + X*4
        txa
        asl
        asl               ; X*4
        tay               ; Y = offset into ctx_key

        lda #0
        sta acc_lo        ; accumulator for dot product

        ; q[0] * key[0] (signed 8-bit multiply approximation)
        ; For small values: just add q[i] if key[i]>0, sub if <0
        ; Actually: score += query[i] * key[i] for 4-bit values
        ; Simplified: XOR-based similarity (hamming match)
        ; Even simpler: just sum matching signs
        
        ; Clean dot product: sum of products
        ; For INT4 hash values (0-3), signed query values (-3..3):
        ; product fits in 8 bits
        lda ctx_query
        sta mag
        lda ctx_key,y
        jsr dot_mul
        lda ctx_query+1
        sta mag
        lda ctx_key+1,y
        jsr dot_mul
        lda ctx_query+2
        sta mag
        lda ctx_key+2,y
        jsr dot_mul
        lda ctx_query+3
        sta mag
        lda ctx_key+3,y
        jsr dot_mul

        ; Compare with best (signed 8-bit)
        sec
        lda acc_lo
        sbc ctx_score
        bvc @at_vc1
        eor #$80
@at_vc1:
        bmi @at_not_best
        ; New best
        lda acc_lo
        sta ctx_score
        stx ctx_best

@at_not_best:
        inx
        cpx #CTX_SLOTS
        bne @at_slot

        ; --- Add best slot's value to hidbuf[0:3] ---
        ; Only if score > 0 (meaningful match)
        lda ctx_score
        bmi @at_done      ; negative score: no match
        beq @at_done      ; zero score: no match

        lda ctx_best
        asl
        asl               ; *4
        tax               ; X = offset into ctx_val

        ; Add to hidbuf with saturation at 255
        clc
        lda hidbuf
        adc ctx_val,x
        bcc @av0
        lda #255
@av0:   sta hidbuf
        clc
        lda hidbuf+1
        adc ctx_val+1,x
        bcc @av1
        lda #255
@av1:   sta hidbuf+1
        clc
        lda hidbuf+2
        adc ctx_val+2,x
        bcc @av2
        lda #255
@av2:   sta hidbuf+2
        clc
        lda hidbuf+3
        adc ctx_val+3,x
        bcc @av3
        lda #255
@av3:   sta hidbuf+3

@at_done:
        rts

; clamp_s3: clamp signed 8-bit A into [-3..3]
clamp_s3:
        cmp #$80
        bcc @cs_pos
        cmp #$FD
        bcs @cs_done
        lda #$FD
        rts
@cs_pos:
        cmp #4
        bcc @cs_done
        lda #3
@cs_done:
        rts

; quant_u2: map unsigned 0..255 into 0..3
quant_u2:
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        rts

; dot_mul: acc_lo += mag * A (both signed 8-bit)
; A is stored in ctx_key and clamped to [-3..3], so this stays bounded.
dot_mul:
        sta act           ; save A
        lda mag
        beq @dm_done
        lda act
        beq @dm_done

        ; Track the sign of the final product.
        lda mag
        eor act
        and #$80
        sta prod_hi

        ; mag = abs(mag)
        lda mag
        bpl @dm_mag_ok
        eor #$FF
        clc
        adc #1
@dm_mag_ok:
        sta mag

        ; act = abs(act), loop counter in tmp (preserves X)
        lda act
        bpl @dm_act_ok
        eor #$FF
        clc
        adc #1
@dm_act_ok:
        sta tmp
        lda #0
@dm_mul:
        clc
        adc mag
        dec tmp
        bne @dm_mul
        sta prod_lo

        lda prod_hi
        bmi @dm_sub
        clc
        lda acc_lo
        adc prod_lo
        sta acc_lo
        rts
@dm_sub:
        sec
        lda acc_lo
        sbc prod_lo
        sta acc_lo
@dm_done:
        rts

; ctx_write: store current context in oldest slot
ctx_write:
        ; Ring buffer write head. This is equivalent to the previous age-based
        ; policy under one-write-per-token usage, but much cheaper.
        lda ctx_wslot
        asl
        asl               ; *4
        tax               ; X = offset

        ; key = ctx_query, quantized to a tiny signed range for bounded attention cost
        lda ctx_query
        jsr clamp_s3
        sta ctx_key,x
        lda ctx_query+1
        jsr clamp_s3
        sta ctx_key+1,x
        lda ctx_query+2
        jsr clamp_s3
        sta ctx_key+2,x
        lda ctx_query+3
        jsr clamp_s3
        sta ctx_key+3,x

        ; value = coarse hidden-state snapshot in 2 bits per channel
        lda hidbuf
        jsr quant_u2
        sta ctx_val,x
        lda hidbuf+1
        jsr quant_u2
        sta ctx_val+1,x
        lda hidbuf+2
        jsr quant_u2
        sta ctx_val+2,x
        lda hidbuf+3
        jsr quant_u2
        sta ctx_val+3,x

        lda ctx_wslot
        clc
        adc #1
        and #$1F
        sta ctx_wslot
        rts

; =====================================================
; Sparse cneuron specialized for JAMXE W2.
; Fast paths cover the common XE W2 nibbles:
;   0, +1, +2, -1, -2
; Falls back to generic mul for rare larger magnitudes.
; =====================================================
cneuron_sparse_w2:
        lda #0
        sta acc_lo
        sta acc_hi
        sta wcnt
@w2l:   ldx wcnt
        cpx frz_count
        bne @w2c0
        jmp @w2d
@w2c0:  ldy frz_off,x
        lda (wptr),y
        bne @w2c00
        jmp @w2nxt
@w2c00: ldy frz_pair,x
        beq @w2lo
        tay
        lda hinib,y
@w2lo:  and #$0F
        bne @w2c01
        jmp @w2nxt
@w2c01:
        stx tmp
        sta mag
        ldx tmp
        lda frz_val,x
        sta act

        lda mag
        cmp #$0F
        bne @w2c1
        jmp @w2m1
@w2c1:  cmp #$01
        bne @w2c2
        jmp @w2p1
@w2c2:  cmp #$02
        bne @w2c3
        jmp @w2p2
@w2c3:  cmp #$0E
        bne @w2c4
        jmp @w2m2
@w2c4:  cmp #$03
        bne @w2c5
        jmp @w2p3
@w2c5:  cmp #$0D
        bne @w2c6
        jmp @w2m3
@w2c6:  cmp #8
        bcs @w2neg

        ; Rare positive 4..7
        lda mag
        jsr mul
        jmp @w2addprod

@w2neg:
        ; Rare negative 8..12 -> abs = 16 - mag
        lda mag
        eor #$0F
        clc
        adc #1
        sta mag
        lda mag
        jsr mul
        jmp @w2subprod

@w2p1:  clc
        lda acc_lo
        adc act
        sta acc_lo
        lda acc_hi
        adc #0
        sta acc_hi
        jmp @w2nx2

@w2m1:  sec
        lda acc_lo
        sbc act
        sta acc_lo
        lda acc_hi
        sbc #0
        sta acc_hi
        jmp @w2nx2

@w2p2:  lda act
        asl
        sta prod_lo
        lda #0
        rol
        sta prod_hi
        jmp @w2addprod

@w2m2:  lda act
        asl
        sta prod_lo
        lda #0
        rol
        sta prod_hi
        jmp @w2subprod

@w2p3:  lda act
        sta prod_lo
        asl
        clc
        adc prod_lo
        sta prod_lo
        lda #0
        adc #0
        sta prod_hi
        jmp @w2addprod

@w2m3:  lda act
        sta prod_lo
        asl
        clc
        adc prod_lo
        sta prod_lo
        lda #0
        adc #0
        sta prod_hi
        jmp @w2subprod

@w2addprod:
        clc
        lda acc_lo
        adc prod_lo
        sta acc_lo
        lda acc_hi
        adc prod_hi
        sta acc_hi
        jmp @w2nx2

@w2subprod:
        sec
        lda acc_lo
        sbc prod_lo
        sta acc_lo
        lda acc_hi
        sbc prod_hi
        sta acc_hi

@w2nx2: ldx tmp
@w2nxt: inc wcnt
        jmp @w2l
@w2d:   rts

; =====================================================
; RODATA
; =====================================================
.segment "RODATA"
twob1:
.repeat 256, i
        .byte (i >> 2) .mod 4
.endrepeat
twob2:
.repeat 256, i
        .byte (i >> 4) .mod 4
.endrepeat
twob3:
.repeat 256, i
        .byte (i >> 6) .mod 4
.endrepeat

; High nibble LUT (same as JAM)
hinib:
.repeat 256, i
        .byte (i >> 4) .mod 16
.endrepeat

; CHARSET: " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-,!?'/"
; Index 0=space, 1-26=A-Z, 27-36=0-9, 37='.', 38='-', 39=','
; 40='!', 41='?', 42="'", 43='/', 44=EOL
us0:    .byte "JUST ASK"
us0l = * - us0
us1:    .byte "NOT SURE"
us1l = * - us1
us2:    .byte "HMM"
us2l = * - us2
us3:    .byte "WHAT"
us3l = * - us3
us4:    .byte "TRY AGAIN"
us4l = * - us4
us5:    .byte "I JAM"
us5l = * - us5
us6:    .byte "WHATEVER"
us6l = * - us6
us7:    .byte "SO CONFUSING"
us7l = * - us7
us_ptrs: .word us0, us1, us2, us3, us4, us5, us6, us7
us_lens: .byte us0l, us1l, us2l, us3l, us4l, us5l, us6l, us7l
charset:
        .byte " ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        .byte "0123456789.-,!?'/"

; === Theme: auto-generated from training data ===
.include "theme_xe.inc"

fb0:    .byte "TRY SOMETHING ELSE"
fb0l = * - fb0
fb1:    .byte "BEATS ME"
fb1l = * - fb1
fb2:    .byte "NOT IN XE RAM"
fb2l = * - fb2
fb_ptrs: .word fb0, fb1, fb2
fb_lens: .byte fb0l, fb1l, fb2l

prm:    .byte "> "
prml = * - prm

; === Weights ===
; sug0-sug7, sug_ptrs, sug_lens: now in theme_xe.inc

w2_data:
b1_data = w2_data + 11520
b2_data = b1_data + 512
b2s_data = b2_data + 45
b2m_data = b2s_data + 45
        .incbin "weights_xe_main.bin"
bank_b1_lo:  .byte <b1_data, <(b1_data+128), <(b1_data+256), <(b1_data+384)
bank_b1_hi:  .byte >b1_data, >(b1_data+128), >(b1_data+256), >(b1_data+384)
bank_hid_lo: .byte <hidbuf, <(hidbuf+128), <(hidbuf+256), <(hidbuf+384)
bank_hid_hi: .byte >hidbuf, >(hidbuf+128), >(hidbuf+256), >(hidbuf+384)
bank_pre_lo: .byte <PREACT_RAM, <(PREACT_RAM+256), <(PREACT_RAM+512), <(PREACT_RAM+768)
bank_pre_hi: .byte >PREACT_RAM, >(PREACT_RAM+256), >(PREACT_RAM+512), >(PREACT_RAM+768)
