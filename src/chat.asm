; ============================================================
; chat.asm - talking to Claude: ASK, NEW, and a typed line that
; is not a command.
;
; CLAUDE.CFG beside the shell names the Messages API endpoint and
; the model (url=, model=); CLAUDE.KEY holds the key. The
; conversation is kept as the JSON text of the "messages" array,
; in a block of its own (hist_seg), and the oldest whole turns go
; when it is full. Each request is built in req_seg: the JSON body
; at BODY_AT, the HTTP head written just in front of it, so the
; two go out as one. The answer's text blocks are decoded into
; req_seg (the request is spent by then) and printed wrapped to
; 80 columns. A turn that fails is forgotten whole.
; ============================================================
BODY_AT         equ 1024
HIST_PARAS      equ 0600h       ; 24 KB of conversation
HIST_MAX        equ HIST_PARAS * 16
PACE_MS         equ 5           ; an answer on the screen: about 200 characters a second
TEXT_AT         equ 8000h       ; where decoded text goes in req_seg
TEXT_MAX        equ 7FF0h
MAX_STEPS       equ 8           ; requests in one turn (tools: phase 7)

        section .text

; ASK question: the rest of the line to Claude.
cmd_ask:
        cmp     byte [in_turn], 0       ; the network is Claude's for now
        je      .free_to_go
        mov     si, msg_busy
        jmp     print_err
.free_to_go:
        call    skip_blanks
        cmp     byte [si], 0
        je      required_missing
        jmp     claude_turn

; NEW: forget the conversation.
cmd_new:
        mov     word [hist_len], 0
        mov     si, msg_forgotten
        jmp     print_z

; claude_ready: CF clear if CLAUDE.CFG names an endpoint and a model.
claude_ready:
        mov     si, key_url
        mov     di, cfg_url
        mov     cx, LINE_MAX
        call    cfg_get
        jc      .no
        mov     si, key_model
        mov     di, cfg_model
        mov     cx, NAME_MAX
        call    cfg_get
        jc      .no
        mov     word [pace_ms], PACE_MS ; pace=n: milliseconds a character
        mov     si, key_pace
        mov     di, pace_buf
        mov     cx, 8
        call    cfg_get
        jc      .ready
        mov     si, pace_buf
        call    parse_num
        jc      .ready
        mov     [pace_ms], ax
.ready: clc
.no:    ret

; claude_turn: the line at SI to Claude, and the answer printed.
claude_turn:
        mov     [turn_text], si
        cmp     byte [in_turn], 0       ; not from inside one of Claude's actions
        je      .not_busy
        mov     si, msg_busy
        jmp     print_err
.not_busy:
        mov     byte [from_keyboard], 0
        call    claude_ready
        jnc     .configured
        mov     si, msg_no_cfg
        jmp     print_err
.configured:
        mov     si, cfg_url
        call    parse_url
        jc      .done
        mov     byte [in_turn], 1
        mov     word [res_len], RES_AT
        mov     byte [results_started], 0
        call    load_key
        call    last_fit                ; big blocks from the top of memory
        cmp     word [hist_seg], 0
        jne     .history
        mov     bx, HIST_PARAS
        mov     ah, 48h
        int     21h
        jc      .no_memory
        mov     [hist_seg], ax
        mov     word [hist_len], 0
.history:
        call    http_buffers
        call    first_fit
        jc      .forget_key

        ; the question goes into the conversation
        mov     si, [turn_text]
        call    strlen
        imul    ax, ax, 2
        add     ax, 64
        mov     [hist_need], ax
        mov     ax, [hist_len]
        mov     [hist_keep], ax
        call    make_room
        jc      .too_long
        mov     ax, [hist_len]
        mov     [hist_mark], ax         ; to go back to if the turn fails
        mov     [hist_keep], ax
        call    hist_comma
        mov     si, js_user_start
        call    hist_add
        push    es
        mov     es, [hist_seg]
        mov     di, [hist_len]
        mov     si, [turn_text]
        call    j_escape
        mov     [hist_len], di
        pop     es
        mov     si, js_user_end
        call    hist_add

        call    net_open
        jc      .failed
        mov     byte [turn_steps], 0
.step:  call    build_request
        jc      .failed_net
        mov     si, msg_thinking
        call    print_err
        call    http_exchange
        pushf
        mov     si, msg_unthink
        call    print_err
        popf
        jc      .failed_net
        call    read_answer
        jc      .failed_net
        cmp     byte [turn_more], 0     ; it asked for actions: their results go back
        je      .finished
        inc     byte [turn_steps]
        cmp     byte [turn_steps], MAX_STEPS
        jb      .step
        mov     si, msg_too_many
        call    print_err
.failed_net:
        call    net_close
.failed:
        mov     ax, [hist_mark]
        mov     [hist_len], ax
        jmp     .free
.finished:
        call    net_close
.free:  call    http_free
.forget_key:
        mov     byte [in_turn], 0
        call    first_fit
        mov     di, api_key             ; it is not kept between turns
        mov     cx, KEY_MAX
        xor     al, al
        rep     stosb
.done:  ret
.too_long:
        mov     si, msg_too_long
        call    print_err
        jmp     .free
.no_memory:
        call    first_fit
        mov     si, msg_net_memory
        call    print_err
        jmp     .forget_key

; last_fit / first_fit: where DOS takes memory from. Blocks that come and
; go are taken from the top, so the memory programs get stays in one piece.
last_fit:
        mov     ax, 5801h
        mov     bx, 2
        int     21h
        ret
first_fit:
        pushf
        mov     ax, 5801h
        xor     bx, bx
        int     21h
        popf
        ret

; load_key: CLAUDE.KEY's first line into api_key (empty if there is none).
load_key:
        mov     byte [api_key], 0
        mov     si, name_key
        call    cfg_path
        mov     dx, pathbuf
        mov     ax, 3D00h
        int     21h
        jc      .done
        mov     bx, ax
        mov     dx, api_key
        mov     cx, KEY_MAX - 1
        mov     ah, 3Fh
        int     21h
        jnc     .read
        xor     ax, ax
.read:  push    ax
        mov     ah, 3Eh
        int     21h
        pop     bx
        mov     byte [api_key + bx], 0
        mov     si, api_key             ; up to the first line end or blank
.c:     lodsb
        cmp     al, ' '
        ja      .c
        mov     byte [si - 1], 0
.done:  ret

; ------------------------------------------------------------
; The conversation
; ------------------------------------------------------------

; hist_add: the ASCIIZ at SI onto the end of the conversation.
hist_add:
        push    es
        mov     es, [hist_seg]
        mov     di, [hist_len]
        call    append_z
        mov     [hist_len], di
        pop     es
        ret

; hist_comma: a comma before the next message, unless it is the first.
hist_comma:
        cmp     word [hist_len], 0
        je      .done
        mov     si, comma_str
        call    hist_add
.done:  ret

; make_room: drop whole turns from the front until hist_need more bytes
; fit, never the part from hist_keep on. CF if that is not enough.
make_room:
        mov     ax, [hist_len]
        add     ax, [hist_need]
        jc      .full
        cmp     ax, HIST_MAX
        jbe     .ok
        ; the next turn starts at the next ',{"role":"user","content":"'
        push    es
        mov     es, [hist_seg]
        mov     bx, 1
.find:  cmp     bx, [hist_keep]
        ja      .not_found
        mov     si, js_turn
        mov     di, bx
.cmp:   lodsb
        test    al, al
        jz      .found
        cmp     al, [es:di]
        jne     .next
        inc     di
        jmp     .cmp
.next:  inc     bx
        jmp     .find
.found: inc     bx                      ; past the comma: the cut
        push    ds
        push    es
        pop     ds
        mov     si, bx
        xor     di, di
        mov     cx, [cs:hist_len]
        sub     cx, bx
        rep     movsb
        pop     ds
        pop     es
        sub     [hist_len], bx
        sub     [hist_keep], bx
        jmp     make_room
.not_found:
        pop     es
.full:  stc
        ret
.ok:    clc
        ret

; ------------------------------------------------------------
; The request and the answer
; ------------------------------------------------------------

; build_request: the whole POST in req_seg; req_start and req_len say
; where it is. CF if it does not fit.
build_request:
        push    es
        mov     es, [req_seg]
        mov     di, BODY_AT
        mov     si, js_model
        call    append_z
        mov     si, cfg_model
        call    j_escape
        mov     si, js_system
        call    append_z
        mov     si, system_prompt
        call    append_z
        ; what the machine is like now: the DOS and the current directory
        mov     si, js_ctx_dos
        call    append_z
        mov     ah, 30h
        int     21h
        mov     [ver_minor], ah
        movzx   eax, al
        push    di
        xor     bl, bl
        call    fmt_u32
        pop     di
        call    append_z
        mov     al, '.'
        stosb
        movzx   ax, byte [ver_minor]
        mov     bl, 10
        div     bl
        add     ax, '00'
        stosw
        mov     si, js_ctx_cwd
        call    append_z
        push    di
        mov     ah, 19h
        int     21h
        add     al, 'A'
        mov     [cwdbuf], al
        mov     word [cwdbuf + 1], ':\'
        mov     si, cwdbuf + 3
        xor     dl, dl
        mov     ah, 47h
        int     21h
        jnc     .cwd
        mov     byte [cwdbuf + 3], 0
.cwd:   pop     di
        mov     si, cwdbuf
        call    j_escape
        mov     si, js_ctx_end
        call    append_z
        call    tools_json              ; phase 7's actions, if any
        mov     si, js_messages
        call    append_z
        ; the conversation
        mov     cx, [hist_len]
        mov     ax, di
        add     ax, cx
        jc      .too_big
        cmp     ax, 0FF00h
        ja      .too_big
        push    ds
        mov     ds, [cs:hist_seg]
        xor     si, si
        rep     movsb
        pop     ds
        mov     ax, ']}'
        stosw
        mov     ax, di
        sub     ax, BODY_AT
        mov     [body_len], ax
        pop     es

        ; the head, in front of the body
        mov     di, hdrbuf
        mov     si, http_post
        call    append_z
        mov     si, url_path
        call    append_z
        mov     si, http_10
        call    append_z
        mov     si, hdr_host
        call    append_z
        mov     si, url_host
        call    append_z
        mov     si, hdr_json
        call    append_z
        cmp     byte [api_key], 0
        je      .no_key
        mov     si, hdr_key
        call    append_z
        mov     si, api_key
        call    append_z
        mov     si, crlf
        call    append_z
.no_key:
        mov     si, hdr_length
        call    append_z
        movzx   eax, word [body_len]
        push    di
        xor     bl, bl
        call    fmt_u32
        pop     di
        call    append_z
        mov     si, crlf
        call    append_z
        mov     si, crlf
        call    append_z
        mov     cx, di
        sub     cx, hdrbuf
        mov     ax, BODY_AT
        sub     ax, cx
        mov     [req_start], ax
        add     cx, [body_len]
        mov     [req_len], cx
        push    es
        mov     es, [req_seg]
        mov     di, [req_start]
        mov     si, hdrbuf
        mov     cx, BODY_AT
        sub     cx, [req_start]
        rep     movsb
        pop     es
        mov     di, hdrbuf              ; it held the key
        mov     cx, HDRBUF_SIZE
        xor     al, al
        rep     stosb
        clc
        ret
.too_big:
        pop     es
        mov     si, msg_too_long
        call    print_err
        stc
        ret

; read_answer: the HTTP answer in http_seg. Its text is printed, its
; content kept in the conversation; turn_more is set if it asked for
; actions (and their results are in the conversation for the next step).
; CF after saying why if the API did not answer as it should.
read_answer:
        mov     byte [turn_more], 0
        push    es
        mov     es, [http_seg]
        mov     ax, [http_len]
        mov     [j_end], ax
        ; the status: "HTTP/1.x 200"
        xor     si, si
        cmp     dword [es:0], 'HTTP'
        jne     .garbled
        mov     si, 9
        mov     cx, 3
        xor     ax, ax
.status:
        mov     bl, [es:si]
        sub     bl, '0'
        cmp     bl, 9
        ja      .garbled
        imul    ax, ax, 10
        movzx   bx, bl
        add     ax, bx
        inc     si
        loop    .status
        mov     [http_status], ax
        ; the body: after the empty line
.body:  cmp     si, [j_end]
        jae     .garbled
        cmp     dword [es:si], 0A0D0A0Dh
        je      .found
        inc     si
        jmp     .body
.found: add     si, 4
        mov     [json_at], si
        cmp     word [http_status], 200
        jne     .api_error
        mov     di, js_content
        call    j_member
        jc      .garbled
        mov     [content_at], si
        call    j_skip
        jc      .garbled
        mov     [content_end], si

        ; keep what Claude said, exactly as it came
        mov     cx, [content_end]
        sub     cx, [content_at]
        add     cx, 40
        mov     [hist_need], cx
        call    make_room
        jc      .too_long
        call    hist_comma
        mov     si, js_assistant
        call    hist_add
        push    ds
        mov     cx, [content_end]
        sub     cx, [content_at]
        mov     si, [content_at]
        mov     di, [hist_len]
        add     [hist_len], cx
        mov     ax, es
        mov     es, [hist_seg]
        mov     ds, ax
        rep     movsb
        pop     ds
        mov     es, [http_seg]
        mov     si, close_brace
        call    hist_add

        ; each block: text is printed, tool_use is acted on
        mov     word [block_no], 0
        mov     byte [results_started], 0
.block: mov     si, [content_at]
        mov     cx, [block_no]
        call    j_element
        jc      .blocks_done
        mov     [block_at], si
        mov     di, js_type
        call    j_member
        jc      .next_block
        mov     di, js_text_type
        call    j_is
        jne     .tool
        mov     si, [block_at]
        mov     di, js_text
        call    j_member
        jc      .next_block
        push    fs
        mov     fs, [req_seg]
        mov     di, TEXT_AT
        mov     cx, TEXT_MAX
        call    j_string
        mov     si, TEXT_AT
        call    print_wrapped
        pop     fs
        jmp     .next_block
.tool:  mov     di, js_tool_use
        call    j_is
        jne     .next_block
        call    tool_use                ; phase 7
.next_block:
        inc     word [block_no]
        jmp     .block
.blocks_done:
        call    tools_done              ; their results into the conversation
        jc      .too_long
        pop     es
        clc
        ret

.api_error:
        ; {"type":"error","error":{"type":...,"message":"..."}}
        mov     si, [json_at]
        mov     di, js_error
        call    j_member
        jc      .garbled
        mov     di, js_message
        call    j_member
        jc      .garbled
        push    fs
        push    ds
        pop     fs
        mov     di, valbuf
        mov     cx, VALBUF_SIZE
        call    j_string
        pop     fs
        pop     es
        mov     si, msg_api_said
        call    print_err
        mov     si, valbuf
        call    print_err
        call    err_newline
        stc
        ret
.garbled:
        pop     es
        mov     si, msg_garbled
        call    print_err
        stc
        ret
.too_long:
        pop     es
        mov     si, msg_too_long
        call    print_err
        stc
        ret

err_newline:
        mov     si, crlf
        jmp     print_err

; print_wrapped: the text at FS:SI, words wrapped at 80 columns, line
; feeds as new lines. On the screen it comes out a character at a
; time, as if Claude were typing it (pace).
print_wrapped:
        mov     byte [wrap_col], 0
        call    pace_start
.next:  mov     al, [fs:si]
        test    al, al
        jz      .end
        cmp     al, 10
        jne     .space
        inc     si
        call    .newline
        jmp     .next
.space: cmp     al, ' '
        jne     .word
        inc     si
        cmp     byte [wrap_col], 79
        jae     .next                   ; at the edge a space is the line break
        mov     dl, ' '
        call    putc
        call    pace
        inc     byte [wrap_col]
        jmp     .next
.word:  mov     bx, si                  ; how long is it?
.len:   mov     al, [fs:bx]
        cmp     al, ' '
        jbe     .measured
        inc     bx
        jmp     .len
.measured:
        mov     cx, bx
        sub     cx, si
        movzx   ax, byte [wrap_col]
        add     ax, cx
        cmp     ax, 80
        jb      .fits
        cmp     byte [wrap_col], 0
        je      .fits
        call    .newline
.fits:  mov     dl, [fs:si]
        call    putc
        call    pace
        inc     si
        inc     byte [wrap_col]
        cmp     byte [wrap_col], 80     ; a word longer than a line breaks anywhere
        jb      .more
        call    .newline
.more:  loop    .fits
        jmp     .next
.end:   cmp     byte [wrap_col], 0
        je      .done
        call    .newline
.done:  ret
.newline:
        mov     byte [wrap_col], 0
        jmp     newline

; pace_start: pace only when the answer goes to the screen (standard
; output is the console device) and CLAUDE.CFG does not say pace=0.
pace_start:
        mov     byte [pace_on], 0
        cmp     word [pace_ms], 0
        je      .done
        mov     ax, 4400h
        mov     bx, 1
        int     21h
        jc      .done
        and     dl, 82h                 ; a device, and the console's output
        cmp     dl, 82h
        jne     .done
        mov     byte [pace_on], 1
.done:  ret

; pace: wait pace_ms after a character. A key pressed (left there for
; the prompt) or a BIOS that cannot wait ends it: the rest at once.
pace:   cmp     byte [pace_on], 0
        je      .done
        push    ax
        push    cx
        push    dx
        mov     ah, 1
        int     16h
        jnz     .stop                   ; a key is waiting
        movzx   eax, word [pace_ms]
        imul    eax, eax, 1000          ; microseconds, in CX:DX
        mov     dx, ax
        shr     eax, 16
        mov     cx, ax
        mov     ah, 86h
        int     15h
        jnc     .waited
.stop:  mov     byte [pace_on], 0
.waited:
        pop     dx
        pop     cx
        pop     ax
.done:  ret

        section .data
key_url         db 'url=', 0
key_model       db 'model=', 0
key_pace        db 'pace=', 0
name_key        db 'CLAUDE.KEY', 0
comma_str       db ',', 0
close_brace     db '}', 0
js_user_start   db '{"role":"user","content":"', 0
js_user_end     db '"}', 0
js_turn         db ',{"role":"user","content":"', 0
js_assistant    db '{"role":"assistant","content":', 0
js_model        db '{"model":"', 0
js_system       db '","max_tokens":1024,"system":"', 0
js_ctx_dos      db ' The machine runs DOS ', 0
js_ctx_cwd      db '; the current directory is ', 0
js_ctx_end      db '.",', 0
js_messages     db '"messages":[', 0
js_content      db 'content', 0
js_type         db 'type', 0
js_text_type    db 'text', 0
js_text         db 'text', 0
js_tool_use     db 'tool_use', 0
js_error        db 'error', 0
js_message      db 'message', 0
http_post       db 'POST ', 0
hdr_json        db 13, 10, 'Content-Type: application/json', 13, 10
                db 'anthropic-version: 2023-06-01', 13, 10, 0
hdr_key         db 'x-api-key: ', 0
hdr_length      db 'Content-Length: ', 0
msg_no_cfg      db 'Claude is not set up: CLAUDE.CFG beside the shell needs url= and model=', 13, 10, 0
msg_thinking    db '(asking Claude...)', 0
msg_unthink     db 13, '                  ', 13, 0
msg_api_said    db 'Claude: ', 0
msg_garbled     db 'Claude: the answer made no sense', 13, 10, 0
msg_too_long    db 'The conversation is too long: NEW starts a new one', 13, 10, 0
msg_too_many    db 'Claude: too many steps in one turn', 13, 10, 0
msg_forgotten   db 'Conversation forgotten', 13, 10, 0

; Already JSON string text: quotes and backslashes are escaped here.
system_prompt:
        db 'You are Claude, built into CLAUDE.COM, a command shell for DOS written in 386 '
        db 'assembly that replaces COMMAND.COM and reaches you over its own TCP/IP stack. '
        db 'The user typed this at its prompt: a question, or a line that is not a DOS command. '
        db 'Answer directly in plain ASCII for an 80-column text screen: brief, no Markdown, '
        db 'no emoji, no tables. Do not imitate a DOS prompt or invent command output. '
        db 'When the question is about this machine, its files, programs or settings, or the '
        db 'user asks you to do something, use the run and write_file actions instead of '
        db 'guessing or telling the user what to type. The user sees every command you run '
        db 'and what it printed, so do not repeat that output: say what it means.', 0

        section .bss
                alignb 2
hist_seg        resw 1
hist_len        resw 1
hist_need       resw 1
hist_keep       resw 1
hist_mark       resw 1
turn_text       resw 1
body_len        resw 1
req_start       resw 1
http_status     resw 1
json_at         resw 1
content_at      resw 1
content_end     resw 1
block_at        resw 1
block_no        resw 1
turn_steps      resb 1
turn_more       resb 1
results_started resb 1
wrap_col        resb 1
pace_on         resb 1
pace_ms         resw 1
pace_buf        resb 8
KEY_MAX         equ 160
HDRBUF_SIZE     equ 768
cfg_url         resb LINE_MAX + 2
cfg_model       resb NAME_MAX + 2
api_key         resb KEY_MAX
hdrbuf          resb HDRBUF_SIZE
