; ============================================================
; batch.asm - batch files: reading them a line at a time, the
; % expansion, CALL and its stack of callers, GOTO, SHIFT, IF
; and FOR.
;
; The running batch file's state is in `bc`. CALL saves it on
; bc_stack and starts the called file in its place; when that
; one ends, its caller comes back. Starting a batch file without
; CALL replaces the running one, as in DOS. The file is reopened
; for every line, as COMMAND.COM does, so a batch file that edits
; itself sees its own changes.
; ============================================================
MAX_CALLS       equ 8
MAX_BATCH_ARGS  equ 24

struc BC
.name   resb 130                ; the full name
.pos    resd 1                  ; where the next line starts
.argc   resw 1                  ; %0 counts
.shift  resw 1                  ; SHIFTs so far
.argoff resw MAX_BATCH_ARGS     ; each argument's offset in .args
.args   resb 224                ; %0 and the arguments, each ending in a 0
endstruc

        section .text

; start_batch: progpath is a batch file, tailbuf its arguments and
; [cmd_start, tok_end) the name it was given as. Run it from its first
; line: in place of the running one, or after saving it if this is a CALL.
start_batch:
        cmp     byte [no_batch], 0      ; not as one of Claude's actions
        je      .allowed
        mov     si, msg_no_batch
        jmp     print_err
.allowed:
        cmp     byte [this_call], 0
        je      .replace
        cmp     byte [batch_active], 0
        je      .replace                ; CALL at the prompt: nothing to come back to
        movzx   ax, byte [bc_level]
        cmp     ax, MAX_CALLS
        jb      .push
        mov     si, msg_too_deep
        jmp     print_err
.push:  mov     bx, BC_size
        mul     bx
        mov     di, bc_stack
        add     di, ax
        mov     si, bc
        mov     cx, BC_size
        rep     movsb
        inc     byte [bc_level]

.replace:
        mov     si, progpath            ; its full name, so a CD in it cannot lose it
        mov     di, bc + BC.name
        mov     ah, 60h
        int     21h
        jnc     .named
        mov     si, progpath
        mov     di, bc + BC.name
        call    append_z
.named: mov     dword [bc + BC.pos], 0
        mov     word [bc + BC.shift], 0
        mov     word [bc + BC.argc], 0
        mov     di, bc + BC.args
        ; %0: the name as it was typed
        call    .arg_start
        mov     si, [cmd_start]
.zero:  cmp     si, [tok_end]
        jae     .zero_end
        movsb
        jmp     .zero
.zero_end:
        xor     al, al
        stosb
        ; %1 on: the words of the command tail
        mov     si, tailbuf + 1
.word:  mov     al, [si]
        cmp     al, 13
        je      .done
        call    is_sep
        jne     .copy
        inc     si
        jmp     .word
.copy:  call    .arg_start
.c:     mov     al, [si]
        cmp     al, 13
        je      .end_word
        call    is_sep
        je      .end_word
        movsb
        jmp     .c
.end_word:
        xor     al, al
        stosb
        jmp     .word
.done:  mov     byte [batch_active], 1
        ret

; record DI as the next argument's start, if there is room for one
.arg_start:
        mov     bx, [bc + BC.argc]
        cmp     bx, MAX_BATCH_ARGS
        jae     .full
        shl     bx, 1
        mov     ax, di
        sub     ax, bc + BC.args
        mov     [bc + BC.argoff + bx], ax
        inc     word [bc + BC.argc]
.full:  ret

; batch_next: the next line of the running batch file, expanded.
; Out: CF clear and SI = the command to run, or CF set when there is
; nothing to run (a label, an empty line, the end of the file).
batch_next:
        mov     eax, [bc + BC.pos]
        mov     [rb_pos], eax
        call    read_batch_line
        jnc     .got
        cmp     byte [rb_missing], 0
        je      .ended
        mov     si, msg_batch_missing
        call    print_err
        call    end_batch
        stc
        ret
.ended: call    batch_done
        stc
        ret
.got:   mov     eax, [rb_pos]
        mov     [bc + BC.pos], eax
        mov     si, linebuf
        call    skip_blanks
        cmp     byte [si], ':'          ; a label is not a command
        je      .skip
        mov     di, expbuf
        call    expand
        mov     si, expbuf
        call    skip_blanks
        mov     al, [si]
        test    al, al
        jz      .skip
        mov     bl, [echo_on]
        cmp     al, '@'
        jne     .echo
        xor     bl, bl
        inc     si
        cmp     byte [echo_on], 0       ; COMMAND.COM still prints the blank line
        je      .echo                   ; that comes before an echoed one
        cmp     byte [quiet_start], 0   ; but not as the very first thing under /C
        jne     .echo
        call    newline
.echo:  mov     byte [quiet_start], 0
        test    bl, bl
        jz      .run
        push    si
        call    show_prompt
        pop     si
        push    si
        call    print_z
        call    newline
        pop     si
.run:   clc
        ret
.skip:  stc
        ret

; read_batch_line: the line of the running batch file at rb_pos into
; linebuf; rb_pos moves on to the next. CF at the end of the file, or
; with rb_missing set if the file is not there any more.
read_batch_line:
        mov     byte [rb_missing], 1
        mov     dx, bc + BC.name
        mov     ax, 3D00h
        int     21h
        jc      .none
        mov     byte [rb_missing], 0
        mov     bx, ax
        mov     dx, [rb_pos]
        mov     cx, [rb_pos + 2]
        mov     ax, 4200h
        int     21h
        mov     dx, batchbuf
        mov     cx, BATCHBUF_SIZE
        mov     ah, 3Fh
        int     21h
        jnc     .read
        xor     ax, ax
.read:  push    ax
        mov     ah, 3Eh
        int     21h
        pop     cx
        jcxz    .none
        mov     si, batchbuf
        mov     di, linebuf
        xor     dx, dx                  ; bytes used up
.ch:    cmp     dx, cx
        jae     .eol
        lodsb
        inc     dx
        cmp     al, 1Ah                 ; ^Z ends a text file
        je      .eof
        cmp     al, 10
        je      .eol
        cmp     al, 13
        je      .cr
        cmp     di, linebuf + LINE_MAX
        jae     .ch                     ; too long: the rest is dropped
        stosb
        jmp     .ch
.cr:    cmp     dx, cx
        jae     .eol
        cmp     byte [si], 10
        jne     .eol
        inc     dx
.eol:   add     [rb_pos], dx
        adc     word [rb_pos + 2], 0
        jmp     .line
.eof:   mov     dword [rb_pos], 7FFFFFFFh  ; the next read finds nothing
.line:  mov     byte [di], 0
        clc
        ret
.none:  stc
        ret

; batch_done: the running batch file has ended; back to its caller, if any.
batch_done:
        cmp     byte [bc_level], 0
        je      end_batch
        dec     byte [bc_level]
        movzx   ax, byte [bc_level]
        mov     bx, BC_size
        mul     bx
        mov     si, bc_stack
        add     si, ax
        mov     di, bc
        mov     cx, BC_size
        rep     movsb
        ret

; end_batch: no batch files at all any more; ECHO is on again at the prompt.
end_batch:
        mov     byte [bc_level], 0
        mov     byte [batch_active], 0
        mov     byte [echo_on], 1
        ret

ask_terminate:
        mov     si, msg_terminate
        call    print_z
.key:   mov     ah, 07h
        int     21h
        call    upcase
        cmp     al, 'Y'
        je      .answer
        cmp     al, 'N'
        jne     .key
.answer:
        push    ax
        mov     dl, al
        call    putc
        call    newline
        pop     ax
        cmp     al, 'Y'
        jne     .done
        call    end_batch
.done:  ret

; expand: the batch line at SI into DI with its % parts replaced:
; %% is %, %0 to %9 the arguments (after any SHIFTs), %NAME% the
; variable (nothing if it is not set). A lone % is dropped.
expand:
        mov     ax, di
        add     ax, LINE_MAX
        mov     [exp_limit], ax
.c:     lodsb
        test    al, al
        jz      .end
        cmp     al, '%'
        je      .pct
.put:   cmp     di, [exp_limit]
        jae     .c
        stosb
        jmp     .c
.pct:   mov     al, [si]
        cmp     al, '%'
        jne     .digit
        inc     si
        jmp     .put
.digit: cmp     al, '0'
        jb      .var
        cmp     al, '9'
        ja      .var
        inc     si
        sub     al, '0'
        movzx   bx, al
        add     bx, [bc + BC.shift]
        cmp     bx, [bc + BC.argc]
        jae     .c                      ; no such argument: nothing
        push    si
        shl     bx, 1
        mov     si, [bc + BC.argoff + bx]
        add     si, bc + BC.args
        call    .copy
        pop     si
        jmp     .c
.var:   mov     bx, si                  ; a name, up to the next %
.find:  mov     al, [bx]
        test    al, al
        jz      .c                      ; none: the % alone is dropped
        cmp     al, '%'
        je      .name
        inc     bx
        jmp     .find
.name:  push    di
        mov     di, namebuf
.n:     cmp     si, bx
        jae     .n_end
        lodsb
        call    upcase
        cmp     di, namebuf + NAME_MAX
        jae     .n
        stosb
        jmp     .n
.n_end: mov     byte [di], 0
        inc     si                      ; past the closing %
        push    si
        mov     si, namebuf
        mov     di, valbuf
        mov     cx, VALBUF_SIZE - 1
        call    env_get
        pop     si
        pop     di
        jc      .c
        push    si
        mov     si, valbuf
        call    .copy
        pop     si
        jmp     .c
.end:   mov     byte [di], 0
        ret
; copy the ASCIIZ at SI to DI, up to the limit
.copy:  lodsb
        test    al, al
        jz      .copied
        cmp     di, [exp_limit]
        jae     .copied
        stosb
        jmp     .copy
.copied:
        ret

; ------------------------------------------------------------
; The batch commands
; ------------------------------------------------------------

; CALL [path]file [arguments]: a batch file runs and then returns here.
cmd_call:
        mov     byte [call_flag], 1
        jmp     execute_line

; SHIFT: %1 becomes %0, %2 becomes %1, and so on.
cmd_shift:
        cmp     byte [batch_active], 0
        je      .done
        inc     word [bc + BC.shift]
.done:  ret

; GOTO label: carry on from the line after :label (8 characters count).
cmd_goto:
        cmp     byte [batch_active], 0
        je      .done
        call    skip_blanks
        cmp     byte [si], ':'
        jne     .label
        inc     si
.label: mov     di, gotobuf
.l:     lodsb
        call    is_sep
        je      .l_end
        call    upcase
        cmp     di, gotobuf + 8
        jae     .l
        stosb
        jmp     .l
.l_end: mov     byte [di], 0
        mov     dword [rb_pos], 0
.scan:  call    read_batch_line
        jc      .not_found
        mov     si, linebuf
        call    skip_blanks
        cmp     byte [si], ':'
        jne     .scan
        inc     si
        mov     di, gotobuf
        mov     cx, 8
.cmp:   lodsb
        call    is_sep
        jne     .letter
        xor     al, al
.letter:
        call    upcase
        cmp     al, [di]
        jne     .scan
        test    al, al
        jz      .found
        inc     di
        loop    .cmp
        cmp     byte [di], 0            ; all 8 the same, and the label stops there
        jne     .scan
.found: mov     eax, [rb_pos]
        mov     [bc + BC.pos], eax
.done:  ret
.not_found:
        mov     si, msg_label_missing
        call    print_err
        jmp     end_batch

; IF [NOT] ERRORLEVEL n | EXIST file | string1==string2  command
cmd_if:
        mov     byte [if_not], 0
        call    skip_blanks
        mov     di, kw_not
        call    match_word
        jc      .cond
        mov     byte [if_not], 1
.cond:  mov     di, kw_errorlevel
        call    match_word
        jnc     .errorlevel
        mov     di, kw_exist
        call    match_word
        jnc     .exist
        ; string1==string2: string1 runs up to the ==
        mov     [if_s1], si
.s1:    mov     al, [si]
        test    al, al
        jz      .syntax
        cmp     word [si], '=='
        je      .s1_end
        inc     si
        jmp     .s1
.s1_end:
        mov     bx, si                  ; BX = the end of string1
.trim:  cmp     bx, [if_s1]
        je      .trimmed
        cmp     byte [bx - 1], ' '
        jne     .trimmed
        dec     bx
        jmp     .trim
.trimmed:
        add     si, 2
        call    skip_blanks
        mov     di, si                  ; string2: one word
.s2:    mov     al, [si]
        test    al, al
        jz      .s2_end
        cmp     al, ' '
        je      .s2_end
        cmp     al, 9
        je      .s2_end
        inc     si
        jmp     .s2
.s2_end:
        mov     cx, bx
        sub     cx, [if_s1]             ; the lengths must match, then every byte
        mov     ax, si
        sub     ax, di
        cmp     ax, cx
        jne     .false
        push    si
        mov     si, [if_s1]
        repe    cmpsb
        pop     si
        jne     .false
        jmp     .true
.errorlevel:
        call    parse_num
        jc      .syntax
        cmp     [errorlevel], al
        jae     .true
        jmp     .false
.exist: mov     di, patbuf
.e:     mov     al, [si]
        cmp     al, ' '
        jbe     .e_end
        movsb
        jmp     .e
.e_end: mov     byte [di], 0
        cmp     di, patbuf
        je      .syntax
        push    si
        mov     dx, dta
        mov     ah, 1Ah
        int     21h
        xor     cx, cx
        mov     dx, patbuf
        mov     ah, 4Eh
        int     21h
        pop     si
        jc      .false
.true:  cmp     byte [if_not], 0
        jne     .no
        jmp     .yes
.false: cmp     byte [if_not], 0
        je      .no
.yes:   call    skip_blanks
        jmp     execute_line
.no:    ret
.syntax:
        mov     si, msg_syntax
        jmp     print_err

; match_word: CF clear and SI past it and the blanks after if the text at
; SI starts with the keyword at DI (upper case) as a whole word.
match_word:
        push    si
.c:     mov     al, [di]
        test    al, al
        jz      .end
        mov     ah, [si]
        xchg    al, ah
        call    upcase
        cmp     al, ah
        jne     .no
        inc     si
        inc     di
        jmp     .c
.end:   mov     al, [si]
        call    is_sep
        jne     .no
        add     sp, 2
        call    skip_blanks
        clc
        ret
.no:    pop     si
        stc
        ret

; FOR %v IN (set) DO command: the command once for each item of the
; set, %v replaced by it. An item with wildcards stands for the files
; it matches, each with the item's own path in front.
cmd_for:
        cmp     byte [for_active], 0
        jne     .nested
        call    skip_blanks
        cmp     byte [si], '%'
        jne     .syntax
        inc     si
        lodsb
        mov     [for_var], al
        call    is_sep
        je      .syntax
        call    skip_blanks
        mov     di, kw_in
        call    match_word
        jc      .syntax
        cmp     byte [si], '('
        jne     .syntax
        inc     si
        mov     di, for_set
.set:   lodsb
        test    al, al
        jz      .syntax
        cmp     al, ')'
        je      .set_end
        cmp     di, for_set + LINE_MAX
        jae     .set
        stosb
        jmp     .set
.set_end:
        mov     byte [di], 0
        call    skip_blanks
        mov     di, kw_do
        call    match_word
        jc      .syntax
        mov     di, for_cmd
        call    append_z
        mov     byte [for_active], 1
        mov     word [for_item], for_set
.next_item:
        mov     si, [for_item]
        call    skip_seps
        cmp     byte [si], 0
        je      .done
        mov     di, for_word
.w:     mov     al, [si]
        call    is_sep
        je      .w_end
        cmp     di, for_word + NAME_MAX * 2
        jae     .w_skip
        stosb
.w_skip:
        inc     si
        jmp     .w
.w_end: mov     byte [di], 0
        mov     [for_item], si
        mov     si, for_word
        call    has_wild
        jc      .wild
        call    for_run
        jmp     .next_item
.wild:  mov     si, for_word
        mov     di, for_path
        call    dir_prefix
        mov     [for_name_at], di
        mov     dx, for_dta
        mov     ah, 1Ah
        int     21h
        xor     cx, cx
        mov     dx, for_word
        mov     ah, 4Eh
        int     21h
        jc      .next_item
.match: mov     di, [for_name_at]
        mov     si, for_dta + 1Eh
        call    append_z
        mov     si, for_path
        call    for_run
        mov     dx, for_dta             ; what ran may have moved the DTA
        mov     ah, 1Ah
        int     21h
        mov     ah, 4Fh
        int     21h
        jnc     .match
        jmp     .next_item
.done:  mov     byte [for_active], 0
        mov     dx, dta
        mov     ah, 1Ah
        int     21h
        ret
.nested:
        mov     si, msg_for_nested
        jmp     print_err
.syntax:
        mov     si, msg_syntax
        jmp     print_err

; for_run: the FOR command with %v replaced by the item at SI, echoed
; first if ECHO is on, then run.
for_run:
        mov     [for_value], si
        mov     si, for_cmd
        mov     di, forline
.c:     lodsb
        test    al, al
        jz      .run
        cmp     al, '%'
        jne     .put
        mov     ah, [si]
        cmp     ah, [for_var]
        jne     .put
        inc     si
        push    si
        mov     si, [for_value]
.v:     lodsb
        test    al, al
        jz      .v_end
        cmp     di, forline + LINE_MAX
        jae     .v_end
        stosb
        jmp     .v
.v_end: pop     si
        jmp     .c
.put:   cmp     di, forline + LINE_MAX
        jae     .c
        stosb
        jmp     .c
.run:   mov     byte [di], 0
        cmp     byte [echo_on], 0
        je      .go
        call    show_prompt
        mov     si, forline
        call    print_z
        call    newline
.go:    mov     si, forline
        jmp     execute_line

        section .data
kw_not          db 'NOT', 0
kw_errorlevel   db 'ERRORLEVEL', 0
kw_exist        db 'EXIST', 0
kw_in           db 'IN', 0
kw_do           db 'DO', 0
msg_too_deep    db 'Batch files are nested too deeply', 13, 10, 0
msg_label_missing db 'Label not found', 13, 10, 0
msg_for_nested  db 'FOR cannot be nested', 13, 10, 0

        section .bss
                alignb 4
rb_pos          resd 1
bc              resb BC_size
bc_stack        resb BC_size * MAX_CALLS
bc_level        resb 1
rb_missing      resb 1
call_flag       resb 1          ; set by CALL for the execute_line it starts
this_call       resb 1          ; ... which keeps it here
if_not          resb 1
quiet_start     resb 1          ; /C, and nothing printed yet
for_active      resb 1
for_var         resb 1
                alignb 2
exp_limit       resw 1
if_s1           resw 1
for_item        resw 1
for_value       resw 1
for_name_at     resw 1
expbuf          resb LINE_MAX + 4
gotobuf         resb 10
for_set         resb LINE_MAX + 2
for_cmd         resb LINE_MAX + 2
for_word        resb NAME_MAX * 2 + 2
for_path        resb NAME_MAX * 2 + 16
forline         resb LINE_MAX + 4
for_dta         resb 44
