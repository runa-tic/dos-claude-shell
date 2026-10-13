; ============================================================
; tools.asm - the actions Claude may take: run a command line
; and see what it printed, or write a text file.
;
; What `run` prints is caught in a temporary file (standard output
; and standard error both point at it while it runs), shown to the
; user and sent back. Anything that may change something needs the
; user's Y first, read straight from the keyboard through the BIOS
; so that no redirected input can answer for them: only a few
; read-only commands run without asking. While Claude's turn holds
; the network and the conversation, the network commands, ASK, batch
; files and EXIT are refused.
;
; The results are collected as JSON in req_seg at RES_AT, and go into
; the conversation as one user message after the answer's blocks.
; ============================================================
OUTPUT_MAX      equ 3000        ; what one command may report back
RES_AT          equ 2000h
RES_END         equ 7E00h

        section .text

; tools_json: the "tools" member of the request, at ES:DI.
tools_json:
        mov     si, tools_text
        jmp     append_z

; tool_use: the tool_use block at block_at (in ES, the answer): do it,
; and add its result to the results.
tool_use:
        push    fs
        push    ds
        pop     fs
        mov     si, [block_at]
        mov     di, js_id
        call    j_member
        jc      .bad
        mov     di, tool_id
        mov     cx, TOOL_ID_MAX
        call    j_string
        jc      .bad
        mov     si, [block_at]
        mov     di, js_name
        call    j_member
        jc      .bad
        mov     di, tool_name
        mov     cx, 32
        call    j_string
        jc      .bad
        mov     si, [block_at]
        mov     di, js_input
        call    j_member
        jc      .bad
        mov     [input_at], si
        pop     fs
        push    es                      ; the answer's segment, for the JSON reads
        push    cs                      ; and ours for everything else
        pop     es

        ; {"type":"tool_result","tool_use_id":"<id>",
        cmp     byte [results_started], 0
        je      .first
        mov     si, comma_str
        call    res_add
.first: mov     byte [results_started], 1
        mov     si, js_result_start
        call    res_add
        mov     si, tool_id
        call    res_esc_z
        mov     si, js_result_id_end
        call    res_add

        mov     si, tool_name
        mov     di, name_run
        call    str_same
        je      .run
        mov     si, tool_name
        mov     di, name_write
        call    str_same
        je      .write
        mov     si, msg_no_action
        jmp     .error
.run:   mov     si, [input_at]
        mov     di, js_command
        call    .answer_es
        call    j_member
        jc      .missing
        push    fs
        push    ds
        pop     fs
        mov     di, tool_cmd
        mov     cx, LINE_MAX
        call    j_string
        pop     fs
        call    .our_es
        jc      .missing
        call    tool_run
        jmp     .end
.write: mov     si, [input_at]
        mov     di, js_path
        call    .answer_es
        call    j_member
        jc      .missing
        push    fs
        push    ds
        pop     fs
        mov     di, tool_path
        mov     cx, NAME_MAX * 2
        call    j_string
        pop     fs
        jc      .missing
        mov     si, [input_at]
        mov     di, js_file_content
        call    j_member
        jc      .missing
        push    fs
        mov     fs, [req_seg]
        mov     di, TEXT_AT
        mov     cx, TEXT_MAX
        call    j_string
        pop     fs
        call    .our_es
        jc      .missing
        call    tool_write
        jmp     .end
.missing:
        call    .our_es
        mov     si, msg_tool_input
.error: push    si
        mov     si, js_error_content
        call    res_add
        pop     si
        call    res_esc_z
.end:   mov     si, js_result_end
        call    res_add
        pop     es
        ret
.bad:   pop     fs
        ret
; ES to the answer's segment (kept on the stack) or back to ours, flags kept
.answer_es:
        mov     es, [http_seg]
        ret
.our_es:
        pushf
        push    cs
        pop     es
        popf
        ret

; tools_done: after the answer's blocks. If it asked for actions, their
; results go into the conversation and turn_more is set. CF if there is
; no room for them.
tools_done:
        cmp     byte [results_started], 0
        je      .done
        mov     cx, [res_len]
        sub     cx, RES_AT
        add     cx, 40
        mov     [hist_need], cx
        call    make_room
        jc      .full
        call    hist_comma
        mov     si, js_results_msg
        call    hist_add
        push    ds
        push    es
        mov     cx, [res_len]
        sub     cx, RES_AT
        mov     di, [hist_len]
        add     [hist_len], cx
        mov     si, RES_AT
        mov     es, [hist_seg]
        mov     ds, [req_seg]
        rep     movsb
        pop     es
        pop     ds
        mov     si, js_results_end
        call    hist_add
        mov     byte [turn_more], 1
.done:  mov     word [res_len], RES_AT
        mov     byte [results_started], 0
        clc
        ret
.full:  stc
        ret

; ------------------------------------------------------------
; run
; ------------------------------------------------------------

tool_run:
        mov     si, msg_claude_runs     ; the user sees what runs
        call    print_z
        mov     si, tool_cmd
        call    print_z
        call    newline
        call    cmd_is_safe
        jnc     .allowed
        call    ask_user
        jnc     .allowed
        mov     si, msg_refused
        jmp     .error
.allowed:
        mov     di, cap_name
        call    make_temp_in
        jnc     .made
        mov     si, msg_no_temp
        jmp     .error
.made:  call    capture_start
        ; the line the user typed may be in the middle of its own
        ; redirection or pipe: keep that aside while this one runs
        mov     eax, [saved_std]
        mov     [outer_std], eax
        mov     dword [saved_std], 0FFFFFFFFh
        mov     ax, [stage]
        mov     [outer_stage], ax
        mov     ax, [next_stage]
        mov     [outer_next], ax
        mov     al, [pipe_more]
        mov     [outer_more], al
        mov     si, pipe_prev
        mov     di, outer_prev
        call    append_z
        mov     byte [pipe_prev], 0
        mov     byte [no_batch], 1
        mov     si, tool_cmd
        call    run_line
        mov     byte [no_batch], 0
        mov     si, outer_prev
        mov     di, pipe_prev
        call    append_z
        mov     al, [outer_more]
        mov     [pipe_more], al
        mov     ax, [outer_next]
        mov     [next_stage], ax
        mov     ax, [outer_stage]
        mov     [stage], ax
        mov     eax, [outer_std]
        mov     [saved_std], eax
        call    capture_stop
        ; what it printed: shown, and sent back
        mov     si, js_content_start
        call    res_add
        call    res_esc_capture
        mov     dx, cap_name
        mov     ah, 41h
        int     21h
        ret
.error: push    si
        call    print_err
        mov     si, crlf
        call    print_err
        mov     si, js_error_content
        call    res_add
        pop     si
        jmp     res_esc_z

; cmd_is_safe: CF clear if the command at tool_cmd only looks: DIR, TYPE,
; VER, VOL, TRUENAME, CD, MEM, ECHO, REM, and SET and PATH with nothing
; to set; nothing redirected or piped.
cmd_is_safe:
        mov     si, tool_cmd
.scan:  lodsb
        test    al, al
        jz      .scanned
        cmp     al, '>'
        je      .unsafe
        cmp     al, '|'
        je      .unsafe
        jmp     .scan
.scanned:
        mov     si, tool_cmd
        call    skip_blanks
        mov     di, safe_words
.word:  cmp     byte [di], 0
        je      .unsafe
        push    si
        mov     bl, [di]                ; 1: anything may follow, 2: nothing may
        inc     di
.c:     mov     al, [di]
        test    al, al
        jz      .name_end
        mov     ah, [si]
        cmp     ah, 'a'
        jb      .cmp
        sub     ah, 20h
.cmp:   cmp     al, ah
        jne     .next
        inc     si
        inc     di
        jmp     .c
.name_end:
        mov     al, [si]                ; the whole word?
        call    is_delim
        jne     .next
        cmp     bl, 2
        jne     .safe
        call    skip_blanks             ; SET, PATH: only to look
        cmp     byte [si], 0
        jne     .next
.safe:  pop     si
        clc
        ret
.next:  pop     si
.skip:  cmp     byte [di], 0            ; on to the next word in the list
        je      .skipped
        inc     di
        jmp     .skip
.skipped:
        inc     di
        jmp     .word
.unsafe:
        stc
        ret

; ask_user: "Allow it? (Y/N)", answered at the keyboard itself. CF unless Y.
ask_user:
        mov     ah, 01h                 ; nothing typed before the question answers it
        int     16h
        jz      .ask
        xor     ah, ah
        int     16h
        jmp     ask_user
.ask:   mov     si, msg_allow
        call    print_err
.key:   xor     ah, ah
        int     16h
        call    upcase
        cmp     al, 'Y'
        je      .yes
        cmp     al, 'N'
        je      .no
        cmp     al, 27
        jne     .key
        mov     al, 'N'
.no:    call    .echo
        stc
        ret
.yes:   call    .echo
        clc
        ret
.echo:  mov     [allow_key], al
        mov     byte [allow_key + 1], 0
        mov     si, allow_key
        call    print_err
        mov     si, crlf
        jmp     print_err

; make_temp_in: a new temporary file, its name in DI (NAME_MAX + 16
; bytes), in %TEMP% or the current drive's root. CF if none.
make_temp_in:
        mov     [temp_dest], di
        mov     si, name_temp
        mov     cx, NAME_MAX
        call    env_get
        jnc     .dir
        mov     di, [temp_dest]
        mov     ah, 19h
        int     21h
        add     al, 'A'
        mov     [di], al
        mov     word [di + 1], ':\'
        mov     byte [di + 3], 0
.dir:   mov     si, [temp_dest]
        call    strlen
        mov     di, [temp_dest]
        add     di, ax
        cmp     byte [di - 1], '\'
        je      .make
        mov     ax, '\'
        stosw
.make:  mov     dx, [temp_dest]
        xor     cx, cx
        mov     ah, 5Ah
        int     21h
        jc      .done
        mov     bx, ax
        mov     ah, 3Eh
        int     21h
        clc
.done:  ret

; capture_start / capture_stop: standard output and error into cap_name,
; and back.
capture_start:
        mov     dx, cap_name
        mov     ax, 3D01h
        int     21h
        jc      .done
        mov     [cap_handle], ax
        mov     bx, 1
        mov     ah, 45h
        int     21h
        mov     [cap_saved1], ax
        mov     bx, 2
        mov     ah, 45h
        int     21h
        mov     [cap_saved2], ax
        mov     bx, [cap_handle]
        mov     cx, 1
        mov     ah, 46h
        int     21h
        mov     bx, [cap_handle]
        mov     cx, 2
        mov     ah, 46h
        int     21h
        mov     bx, [cap_handle]
        mov     ah, 3Eh
        int     21h
        mov     byte [cap_active], 1
.done:  ret
capture_stop:
        cmp     byte [cap_active], 0
        je      .done
        mov     bx, [cap_saved1]
        mov     cx, 1
        mov     ah, 46h
        int     21h
        mov     bx, [cap_saved1]
        mov     ah, 3Eh
        int     21h
        mov     bx, [cap_saved2]
        mov     cx, 2
        mov     ah, 46h
        int     21h
        mov     bx, [cap_saved2]
        mov     ah, 3Eh
        int     21h
        mov     byte [cap_active], 0
.done:  ret

; res_esc_capture: the captured file printed as it is and escaped into
; the result (at most OUTPUT_MAX characters of it).
res_esc_capture:
        mov     word [cap_left], OUTPUT_MAX
        mov     byte [cap_any], 0
        mov     dx, cap_name
        mov     ax, 3D00h
        int     21h
        jc      .nothing
        mov     [cap_handle], ax
.read:  mov     bx, [cap_handle]
        mov     dx, iobuf
        mov     cx, IOBUF_SIZE
        mov     ah, 3Fh
        int     21h
        jc      .close
        test    ax, ax
        jz      .close
        mov     cx, ax
        mov     byte [cap_any], 1
        push    cx
        mov     dx, iobuf
        mov     bx, 1
        mov     ah, 40h
        int     21h
        pop     cx
        mov     si, iobuf
.c:     cmp     word [cap_left], 0
        je      .read
        lodsb
        call    res_esc_char
        dec     word [cap_left]
        loop    .c
        jmp     .read
.close: mov     bx, [cap_handle]
        mov     ah, 3Eh
        int     21h
        cmp     byte [cap_any], 0
        jne     .done
.nothing:
        mov     si, msg_no_output
        call    res_esc_z
.done:  ret

; ------------------------------------------------------------
; write_file
; ------------------------------------------------------------

; tool_write: the decoded text at req_seg:TEXT_AT into tool_path, each
; line feed written as CR LF.
tool_write:
        push    es
        mov     es, [req_seg]           ; how big?
        mov     si, TEXT_AT
        xor     bx, bx
.count: cmp     byte [es:si], 0
        je      .counted
        inc     bx
        inc     si
        jmp     .count
.counted:
        pop     es
        mov     [write_bytes], bx
        mov     si, msg_claude_writes
        call    print_z
        mov     si, tool_path
        call    print_z
        mov     si, msg_paren
        call    print_z
        mov     ax, [write_bytes]
        call    put_dec
        mov     si, msg_bytes_close
        call    print_z
        call    ask_user
        jnc     .allowed
        mov     si, msg_refused
        jmp     .error
.allowed:
        mov     dx, tool_path
        xor     cx, cx
        mov     ah, 3Ch
        int     21h
        jnc     .open
        mov     si, msg_cannot_write
        jmp     .error
.open:  mov     [cap_handle], ax
        push    es
        mov     es, [req_seg]
        mov     si, TEXT_AT
        mov     di, iobuf
.w:     mov     al, [es:si]
        test    al, al
        jz      .last
        inc     si
        cmp     al, 10
        jne     .put
        mov     byte [di], 13
        inc     di
.put:   mov     [di], al
        inc     di
        cmp     di, iobuf + IOBUF_SIZE - 2
        jb      .w
        call    .flush
        jmp     .w
.last:  call    .flush
        pop     es
        mov     bx, [cap_handle]
        mov     ah, 3Eh
        int     21h
        mov     si, js_content_start
        call    res_add
        mov     si, msg_written
        call    res_esc_z
        mov     si, tool_path
        jmp     res_esc_z
.flush: mov     cx, di
        sub     cx, iobuf
        jcxz    .flushed
        mov     dx, iobuf
        mov     bx, [cap_handle]
        mov     ah, 40h
        int     21h
.flushed:
        mov     di, iobuf
        ret
.error: push    si
        call    print_err
        mov     si, crlf
        call    print_err
        mov     si, js_error_content
        call    res_add
        pop     si
        jmp     res_esc_z

; ------------------------------------------------------------
; The results, as JSON in req_seg
; ------------------------------------------------------------

; res_add: the ASCIIZ at SI as it is.
res_add:
        push    es
        mov     es, [req_seg]
        mov     di, [res_len]
.c:     lodsb
        test    al, al
        jz      .end
        cmp     di, RES_END
        jae     .c
        stosb
        jmp     .c
.end:   mov     [res_len], di
        pop     es
        ret

; res_esc_z: the ASCIIZ at SI, escaped for a JSON string.
res_esc_z:
        lodsb
        test    al, al
        jz      .done
        call    res_esc_char
        jmp     res_esc_z
.done:  ret

; res_esc_char: AL escaped for a JSON string. CR is dropped, LF is \n,
; a tab a space, other control characters left out, anything past
; ASCII '?'.
res_esc_char:
        push    es
        push    di
        mov     es, [req_seg]
        mov     di, [res_len]
        cmp     di, RES_END - 8         ; room kept for the closing
        jae     .done
        cmp     al, 13
        je      .done
        cmp     al, 10
        jne     .tab
        mov     byte [es:di], '\'
        inc     di
        mov     al, 'n'
        jmp     .put
.tab:   cmp     al, 9
        jne     .ctrl
        mov     al, ' '
.ctrl:  cmp     al, ' '
        jb      .done
        cmp     al, 127
        jb      .quote
        mov     al, '?'
.quote: cmp     al, '"'
        je      .esc
        cmp     al, '\'
        jne     .put
.esc:   mov     byte [es:di], '\'
        inc     di
.put:   stosb
.done:  mov     [res_len], di
        pop     di
        pop     es
        ret

        section .data
name_run        db 'run', 0
name_write      db 'write_file', 0
js_id           db 'id', 0
js_name         db 'name', 0
js_input        db 'input', 0
js_command      db 'command', 0
js_path         db 'path', 0
js_file_content db 'content', 0
js_result_start db '{"type":"tool_result","tool_use_id":"', 0
js_result_id_end db '",', 0
js_content_start db '"content":"', 0
js_error_content db '"is_error":true,"content":"', 0
js_result_end   db '"}', 0
js_results_msg  db '{"role":"user","content":[', 0
js_results_end  db ']}', 0
; the commands that only look; 1: with anything after, 2: with nothing after
safe_words      db 1, 'DIR', 0, 1, 'TYPE', 0, 1, 'VER', 0, 1, 'VOL', 0, 1, 'TRUENAME', 0
                db 1, 'CD', 0, 1, 'CHDIR', 0, 1, 'MEM', 0, 1, 'ECHO', 0, 1, 'REM', 0
                db 2, 'SET', 0, 2, 'PATH', 0, 0
msg_claude_runs db 'Claude runs: ', 0
msg_claude_writes db 'Claude wants to write ', 0
msg_paren       db ' (', 0
msg_bytes_close db ' bytes)', 13, 10, 0
msg_allow       db 'Allow it? (Y/N) ', 0
msg_refused     db 'The user did not allow it.', 0
msg_no_action   db 'There is no such action.', 0
msg_tool_input  db 'The action is missing what it needs.', 0
msg_no_temp     db 'No temporary file could be made for the output.', 0
msg_no_output   db '(it printed nothing)', 0
msg_cannot_write db 'The file could not be created.', 0
msg_written     db 'Written: ', 0
msg_busy        db 'Not while Claude is acting', 13, 10, 0
msg_no_batch    db 'Batch files cannot be run from here', 13, 10, 0

tools_text:
        db '"tools":[{"name":"run","description":"Run one command line in CLAUDE.COM, the DOS '
        db 'shell the user is in, and get back what it printed (at most 3000 characters). It has '
        db 'the internal commands of COMMAND.COM (DIR, CD, MD, RD, COPY, DEL, REN, TYPE, ECHO, '
        db 'SET, PATH, VER, VOL, TRUENAME) and runs .COM and .EXE programs found along PATH; '
        db '< > >> and | work. Batch files, NET, PING, FETCH and ASK cannot run here. Never run a '
        db 'program that waits for keys or takes over the screen (EDIT, DATE or TIME without a '
        db 'value). The user sees the command and its output. Anything that may change something '
        db 'is shown to the user first, who may refuse it.","input_schema":{"type":"object",'
        db '"properties":{"command":{"type":"string"}},"required":["command"]}},'
        db '{"name":"write_file","description":"Create a text file, or replace one, with the '
        db 'given content. The user is shown its name and size and may refuse.","input_schema":'
        db '{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},'
        db '"required":["path","content"]}}],', 0

        section .bss
                alignb 4
outer_std       resd 1
res_len         resw 1
input_at        resw 1
temp_dest       resw 1
cap_handle      resw 1
cap_saved1      resw 1
cap_saved2      resw 1
cap_left        resw 1
outer_stage     resw 1
outer_next      resw 1
write_bytes     resw 1
outer_more      resb 1
cap_active      resb 1
cap_any         resb 1
no_batch        resb 1
in_turn         resb 1
allow_key       resb 2
TOOL_ID_MAX     equ 80
tool_id         resb TOOL_ID_MAX
tool_name       resb 34
tool_cmd        resb LINE_MAX + 2
tool_path       resb NAME_MAX * 2 + 2
cap_name        resb NAME_MAX + 16
outer_prev      resb NAME_MAX + 16
