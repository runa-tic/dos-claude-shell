; ============================================================
; redir.asm - redirection and pipes.
;
; run_line is how a whole line runs, from the keyboard or a batch
; file: it splits it at each |, takes the < file, > file and
; >> file parts out of every stage, points standard input and
; output at those files (DOS handle duplication, AH=45h/46h), runs
; the stage through execute_line, and puts the handles back. Each
; stage of a pipe writes to a temporary file (AH=5Ah, in %TEMP% or
; the current drive's root) that the next stage reads, as DOS does
; it. IF, FOR and CALL hand the rest of their line straight to
; execute_line, so a redirection applies to the whole line.
; ============================================================
        section .text

run_line:
        mov     di, pipe_buf
        call    append_z
        mov     word [stage], pipe_buf
        mov     byte [pipe_prev], 0     ; no temporary file to read from yet

.stage: ; this stage ends at the next | (or the end of the line)
        mov     byte [pipe_next], 0
        mov     si, [stage]
.find:  lodsb
        test    al, al
        jz      .last
        cmp     al, '|'
        jne     .find
        mov     byte [si - 1], 0
        mov     [next_stage], si
        mov     byte [pipe_more], 1
        jmp     .split
.last:  mov     byte [pipe_more], 0

.split: call    split_redirections
        jc      .done                   ; a bad redirection: nothing more runs

        ; standard input: the stage before, or a < file
        cmp     byte [pipe_prev], 0
        je      .in_file
        mov     dx, pipe_prev
        mov     ax, 3D00h
        int     21h
        jc      .in_file
        xor     bx, bx
        call    redirect_handle
.in_file:
        cmp     byte [redir_in], 0
        je      .out
        mov     dx, redir_in
        mov     ax, 3D00h
        int     21h
        jnc     .in_open
        call    print_dos_error
        jmp     .undo
.in_open:
        xor     bx, bx
        call    redirect_handle

.out:   ; standard output: a > or >> file, or the next stage's temporary file
        cmp     byte [redir_out], 0
        je      .pipe_out
        mov     dx, redir_out
        cmp     byte [redir_append], 0
        je      .create
        mov     ax, 3D01h
        int     21h
        jc      .create
        mov     bx, ax
        push    ax
        mov     ax, 4202h               ; >> writes at the end
        xor     cx, cx
        xor     dx, dx
        int     21h
        pop     ax
        jmp     .out_open
.create:
        mov     dx, redir_out
        xor     cx, cx
        mov     ah, 3Ch
        int     21h
        jnc     .out_open
        call    print_dos_error
        jmp     .undo
.out_open:
        mov     bx, 1
        call    redirect_handle
        jmp     .run
.pipe_out:
        cmp     byte [pipe_more], 0
        je      .run
        call    make_temp
        jc      .undo
        mov     bx, 1
        call    redirect_handle

.run:   mov     si, seg_cmd
        call    execute_line

.undo:  call    undo_redirection
        cmp     byte [pipe_prev], 0     ; the stage before's file has been read
        je      .moved
        mov     dx, pipe_prev
        mov     ah, 41h
        int     21h
.moved: mov     si, pipe_next
        mov     di, pipe_prev
        call    append_z
        cmp     byte [pipe_more], 0
        je      .done
        mov     ax, [next_stage]
        mov     [stage], ax
        jmp     .stage
.done:  cmp     byte [pipe_prev], 0     ; a pipe cut short leaves its file behind
        je      .clean
        mov     dx, pipe_prev
        mov     ah, 41h
        int     21h
        mov     byte [pipe_prev], 0
.clean: ret

; split_redirections: the stage at [stage] as seg_cmd (the command without
; its redirections), redir_in, redir_out and redir_append. CF after saying
; so if a < or > has no file name.
split_redirections:
        mov     byte [redir_in], 0
        mov     byte [redir_out], 0
        mov     byte [redir_append], 0
        mov     si, [stage]
        mov     di, seg_cmd
.c:     lodsb
        test    al, al
        jz      .end
        cmp     al, '<'
        je      .in
        cmp     al, '>'
        je      .out
        stosb
        jmp     .c
.in:    mov     bx, redir_in
        jmp     .name
.out:   mov     bx, redir_out
        mov     byte [redir_append], 0
        cmp     byte [si], '>'
        jne     .name
        inc     si
        mov     byte [redir_append], 1
.name:  push    di
        call    skip_blanks
        mov     di, bx
.n:     mov     al, [si]
        cmp     al, ' '
        jbe     .n_end
        cmp     al, '<'
        je      .n_end
        cmp     al, '>'
        je      .n_end
        mov     dx, bx
        add     dx, NAME_MAX * 2
        cmp     di, dx
        jae     .n_skip
        stosb
.n_skip:
        inc     si
        jmp     .n
.n_end: mov     byte [di], 0
        cmp     di, bx
        pop     di
        jne     .c
        mov     si, msg_redir_name
        call    print_err
        stc
        ret
.end:   stosb
        clc
        ret

; redirect_handle: make standard handle BX (0 or 1) refer to the file
; open as AX, keeping the original to put back; the file's own handle
; is closed (the duplicate keeps it open).
redirect_handle:
        mov     [rh_file], ax
        mov     [rh_std], bx
        mov     si, bx
        shl     si, 1
        cmp     word [saved_std + si], 0FFFFh   ; the first time: keep the original
        jne     .saved
        mov     ah, 45h
        int     21h
        jc      .saved
        mov     [saved_std + si], ax
.saved: mov     bx, [rh_file]
        mov     cx, [rh_std]
        mov     ah, 46h
        int     21h
        mov     bx, [rh_file]
        mov     ah, 3Eh
        int     21h
        ret

; undo_redirection: standard input and output back to what they were.
undo_redirection:
        xor     bx, bx
        call    .one
        mov     bx, 1
.one:   mov     si, bx
        shl     si, 1
        mov     ax, [saved_std + si]
        cmp     ax, 0FFFFh
        je      .done
        mov     cx, bx
        mov     bx, ax
        mov     ah, 46h
        int     21h
        mov     ah, 3Eh                 ; BX is still the saved copy
        int     21h
        mov     word [saved_std + si], 0FFFFh
.done:  ret

; make_temp: a new temporary file for a pipe, its name in pipe_next.
; Out: AX = its handle, open for writing; CF after saying so if none.
make_temp:
        mov     si, name_temp
        mov     di, pipe_next
        mov     cx, NAME_MAX
        call    env_get
        jnc     .dir
        mov     ah, 19h                 ; no TEMP: the current drive's root
        int     21h
        add     al, 'A'
        mov     [pipe_next], al
        mov     word [pipe_next + 1], ':\'
        mov     byte [pipe_next + 3], 0
.dir:   mov     di, pipe_next
        mov     si, di
        call    strlen
        add     di, ax
        cmp     byte [di - 1], '\'
        je      .make
        mov     ax, '\'
        stosw
.make:  mov     dx, pipe_next
        xor     cx, cx
        mov     ah, 5Ah                 ; DOS adds a unique name and creates it
        int     21h
        jnc     .done
        call    print_dos_error
        stc
.done:  ret

        section .data
name_temp       db 'TEMP', 0
msg_redir_name  db 'File creation error', 13, 10, 0

        section .bss
                alignb 2
saved_std       resw 2          ; standard input and output while redirected, else FFFFh
rh_file         resw 1
rh_std          resw 1
stage           resw 1
next_stage      resw 1
pipe_more       resb 1
redir_append    resb 1
pipe_buf        resb LINE_MAX + 4
seg_cmd         resb LINE_MAX + 4
redir_in        resb NAME_MAX * 2 + 4
redir_out       resb NAME_MAX * 2 + 4
pipe_prev       resb NAME_MAX + 16      ; the stage before's temporary file
pipe_next       resb NAME_MAX + 16      ; this stage's
