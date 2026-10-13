; ============================================================
; CLAUDE.COM - a shell for DOS that talks to Claude.
;
; Phase 1: the shell core. It reads a line, runs the program the
; line names (a .COM, an .EXE or a batch file, looked for in the
; current directory and then along PATH), handles Ctrl-C and
; critical errors, and can be the system shell (SHELL= in
; CONFIG.SYS) with no COMMAND.COM anywhere. Internal commands so
; far: EXIT, REM, and drive changes such as A:.
;
; Switches, as COMMAND.COM takes them:
;   /P[=file]  permanent; run the startup batch file (\AUTOEXEC.BAT
;              unless a file is named, as FreeCOM's /P=\FDAUTO.BAT)
;   /D         skip the startup file
;   /C cmd     run one command, then exit with its errorlevel
;   /K cmd     run one command, then stay
; A leading directory and /E:n are accepted and ignored for now.
;
; Batch files run one line at a time, reopened for every line as
; COMMAND.COM does; '@' hides a line and ':' lines are labels.
; Their %1, IF, GOTO, CALL and the rest come in phase 3.
;
; 386 real mode: 32-bit registers are allowed, but DOS and BIOS
; calls only promise to keep the low 16 bits of each register.
;
; Build: nasm -f bin src/claude.asm -o build/claude.com
; ============================================================
        cpu     386
        bits    16
        org     100h

PSP_INT22       equ 0Ah         ; where DOS goes when this process ends
PSP_INT23       equ 0Eh         ; Ctrl-C vector DOS restores at the end
PSP_INT24       equ 12h         ; critical error vector, likewise
PSP_PARENT      equ 16h
PSP_ENV         equ 2Ch
PSP_TAIL        equ 80h

LINE_MAX        equ 126         ; the longest command tail DOS can pass on
NAME_MAX        equ 64          ; a command name, a PATH entry

T_COM           equ 0
T_EXE           equ 1
T_BAT           equ 2

start:
        cld
        mov     di, bss_start           ; DOS does not clear it for us
        mov     cx, bss_end - bss_start
        xor     al, al
        rep     stosb
        mov     sp, stack_top

        ; A .COM is given all free memory. Keep our own block only, so
        ; the programs we run get the rest.
        mov     bx, stack_top + 15
        shr     bx, 4
        mov     ah, 4Ah
        int     21h

        call    parse_switches
        call    check_root

        mov     dx, dta
        mov     ah, 1Ah
        int     21h
        mov     dx, on_break
        mov     ax, 2523h
        int     21h
        mov     dx, on_critical
        mov     ax, 2524h
        int     21h

        ; A permanent shell is its own parent, so that DOS never really
        ; ends it: an Abort or Ctrl-C that ends "this program" comes back
        ; through INT 22h to a fresh prompt, with our handlers restored.
        cmp     byte [permanent], 0
        je      .handlers_done
        mov     word [PSP_INT22], restart
        mov     [PSP_INT22 + 2], cs
        mov     word [PSP_INT23], on_break
        mov     [PSP_INT23 + 2], cs
        mov     word [PSP_INT24], on_critical
        mov     [PSP_INT24 + 2], cs
        mov     [PSP_PARENT], cs
.handlers_done:

        cmp     byte [mode], 'C'
        je      .quiet
        call    banner
.quiet:
        cmp     byte [mode], 0
        je      .startup
        cmp     byte [mode], 'C'
        jne     .oneshot
        mov     byte [exit_after], 1
.oneshot:
        mov     si, [oneshot]
        call    execute_line
        jmp     main_loop

.startup:
        cmp     byte [want_startup], 0
        je      main_loop
        cmp     byte [no_startup], 0
        jne     main_loop
        mov     si, startup_name
        cmp     byte [si], 0
        jne     .named
        mov     si, default_startup
.named: mov     di, progpath
.copy:  lodsb
        stosb
        test    al, al
        jnz     .copy
        mov     dx, progpath
        call    exists
        jc      main_loop               ; no startup file: just a prompt
        mov     byte [tailbuf], 0
        mov     byte [tailbuf + 1], 13
        call    start_batch
        ; fall through

; ------------------------------------------------------------
; The shell's loop: the next batch line if a batch file is
; running, else a line from the keyboard.
; ------------------------------------------------------------
main_loop:
        cmp     byte [batch_active], 0
        jne     .batch
        cmp     byte [exit_after], 0
        jne     .exit
        call    read_command
        mov     si, linebuf
        jmp     .run
.batch: call    batch_next
        jc      main_loop
.run:   call    execute_line
        jmp     main_loop
.exit:  mov     byte [exit_after], 0
        call    do_exit
        jmp     main_loop

; Prompt, then a line from standard input into linebuf (ASCIIZ).
read_command:
        call    show_prompt
        mov     ax, 4400h               ; is standard input the console or a file?
        xor     bx, bx
        int     21h
        jc      .console
        test    dl, 80h
        jz      .file
.console:
        mov     byte [inbuf], LINE_MAX + 1
        mov     dx, inbuf
        mov     ah, 0Ah                 ; DOS line editing (and DOSKEY, if loaded)
        int     21h
        mov     si, crlf
        call    print_z
        movzx   cx, byte [inbuf + 1]
        mov     si, inbuf + 2
        mov     di, linebuf
        rep     movsb
        mov     byte [di], 0
        jmp     .got

        ; From a file: a byte at a time up to the line feed, echoed as if
        ; typed. At the end of the file, leave as if EXIT had been typed.
.file:  mov     di, linebuf
.byte:  push    di
        mov     dx, inbuf
        mov     cx, 1
        xor     bx, bx
        mov     ah, 3Fh
        int     21h
        pop     di
        jc      .eof
        test    ax, ax
        jz      .eof
        mov     al, [inbuf]
        cmp     al, 10
        je      .line
        cmp     al, 1Ah
        je      .eof
        cmp     al, 13
        je      .byte
        cmp     di, linebuf + LINE_MAX
        jae     .byte
        stosb
        jmp     .byte
.eof:   cmp     di, linebuf
        jne     .line                   ; a last line with no line feed still runs
        mov     byte [di], 0
        mov     si, crlf
        call    print_z
        call    do_exit
        jmp     .got
.line:  mov     byte [di], 0
        mov     si, linebuf
        call    print_z
        mov     si, crlf
        call    print_z
.got:   cmp     byte [linebuf], 0
        jne     .done
        mov     byte [no_blank], 1      ; an empty line: no blank line before the next prompt
.done:  ret

; The prompt, $P$G for now: the current drive and directory.
show_prompt:
        cmp     byte [no_blank], 0
        mov     byte [no_blank], 0
        jne     .drive
        mov     si, crlf
        call    print_z
.drive: mov     ah, 19h
        int     21h
        add     al, 'A'
        mov     [cwdbuf], al
        mov     byte [cwdbuf + 1], ':'
        mov     byte [cwdbuf + 2], '\'
        mov     si, cwdbuf + 3
        xor     dl, dl
        mov     ah, 47h
        int     21h
        jnc     .show
        mov     byte [cwdbuf + 3], 0
.show:  mov     si, cwdbuf
        call    print_z
        mov     dl, '>'
        jmp     putc

; EXIT, and the end of /C: a permanent shell stays.
do_exit:
        cmp     byte [permanent], 0
        jne     .stay
        mov     al, [errorlevel]
        mov     ah, 4Ch
        int     21h
.stay:  ret

; ------------------------------------------------------------
; execute_line: run the command line at SI (ASCIIZ).
; ------------------------------------------------------------
execute_line:
        call    skip_blanks
        cmp     byte [si], 0
        je      .ret
        mov     [cmd_start], si
        mov     di, cmdname
        mov     cx, NAME_MAX
.tok:   lodsb
        call    is_delim
        je      .tok_end
        call    upcase
        stosb
        loop    .tok
        jmp     bad_command             ; a name longer than any path
.tok_end:
        dec     si
        mov     [tok_end], si
        mov     byte [di], 0

        ; X: changes the current drive
        mov     ax, di
        sub     ax, cmdname
        cmp     ax, 2
        jne     .internal
        cmp     byte [cmdname + 1], ':'
        je      change_drive

.internal:
        mov     bx, internals
.next:  mov     si, [bx]
        test    si, si
        jz      .external
        mov     di, cmdname
.cmp:   lodsb
        test    al, al
        jz      .name_end
        cmp     al, [di]
        jne     .skip
        inc     di
        jmp     .cmp
.name_end:
        ; CD.. and ECHO. are CD and ECHO: a name may run into a dot or a backslash
        mov     al, [di]
        test    al, al
        jz      .found
        cmp     al, '.'
        je      .found
        cmp     al, '\'
        je      .found
.skip:  add     bx, 4
        jmp     .next
.found: sub     di, cmdname             ; the arguments start right after the name
        add     di, [cmd_start]
        mov     si, di
        jmp     [bx + 2]

.external:
        mov     si, [tok_end]
        call    build_tail
        call    find_program
        jc      bad_command
        cmp     byte [prog_type], T_BAT
        je      start_batch
        jmp     run_program
.ret:   ret

bad_command:
        mov     si, msg_bad_command
        jmp     print_z

change_drive:
        mov     dl, [cmdname]
        sub     dl, 'A'
        cmp     dl, 25
        ja      .bad
        mov     bl, dl
        mov     ah, 0Eh
        int     21h
        mov     ah, 19h                 ; DOS does not refuse a drive that is not there;
        int     21h                     ; it just stays where it was
        cmp     al, bl
        je      .ok
.bad:   mov     si, msg_bad_drive
        jmp     print_z
.ok:    ret

internals:
        dw      name_exit, cmd_exit
        dw      name_rem, cmd_rem
        dw      0

cmd_exit:
        jmp     do_exit

cmd_rem:
        ret

; ------------------------------------------------------------
; Programs
; ------------------------------------------------------------

; build_tail: the rest of the line at SI, as a command tail:
; a length byte, the text as typed (leading space included), CR.
build_tail:
        mov     di, tailbuf + 1
        xor     cx, cx
.c:     lodsb
        test    al, al
        jz      .done
        cmp     cx, LINE_MAX
        jae     .done
        stosb
        inc     cx
        jmp     .c
.done:  mov     byte [di], 13
        mov     [tailbuf], cl
        ret

; find_program: look for cmdname as a program. If it names a path
; (it has a ':' or a '\'), only there; otherwise in the current
; directory and then in each PATH directory. Without an extension
; .COM, .EXE and .BAT are tried in that order in each directory.
; Out: CF clear, progpath and prog_type set when found.
find_program:
        mov     dx, dta                 ; a program we ran may have moved it
        mov     ah, 1Ah
        int     21h
        mov     byte [has_path], 0
        mov     byte [crit_failed], 0
        mov     byte [ext_type], 0FFh
        mov     si, cmdname
        mov     bx, si                  ; BX = the start of the file name part
.scan:  lodsb
        test    al, al
        jz      .scanned
        cmp     al, '*'
        je      .none
        cmp     al, '?'
        je      .none
        cmp     al, ':'
        je      .sep
        cmp     al, '\'
        jne     .scan
.sep:   mov     bx, si
        mov     byte [has_path], 1
        jmp     .scan
.scanned:
        mov     si, bx
.dot:   lodsb
        test    al, al
        jz      .look
        cmp     al, '.'
        jne     .dot
        call    ext_kind                ; an extension must be one we can run
        jc      .none
        mov     [ext_type], al

.look:  mov     byte [dirbuf], 0        ; the current directory, or the path as typed
        call    try_dir
        jnc     .found
        cmp     byte [crit_failed], 0
        jne     .none
        cmp     byte [has_path], 0
        jne     .none
        call    find_path
        jc      .none
.entry: push    ds                      ; copy one PATH entry into dirbuf
        mov     ds, [cs:PSP_ENV]
        mov     di, dirbuf
        xor     cx, cx
.ch:    lodsb
        test    al, al
        jz      .last
        cmp     al, ';'
        je      .entry_end
        cmp     cx, NAME_MAX
        jae     .ch
        stosb
        inc     cx
        jmp     .ch
.last:  dec     si                      ; stay on the 0: the list has ended
.entry_end:
        pop     ds
        mov     byte [di], 0
        mov     [path_pos], si
        jcxz    .after
        call    try_dir
        jnc     .found
        cmp     byte [crit_failed], 0   ; a drive that failed: stop looking
        jne     .none
.after: mov     si, [path_pos]
        push    ds
        mov     ds, [cs:PSP_ENV]
        mov     al, [si]
        pop     ds
        test    al, al
        jnz     .entry
.none:  stc
        ret
.found: clc
        ret

; ext_kind: SI = an extension (upper case, ASCIIZ).
; Out: AL = T_COM, T_EXE or T_BAT, or CF set if it is none of them.
ext_kind:
        mov     di, exts
        xor     ax, ax
.e:     push    si
        push    di
        mov     cx, 4
        repe    cmpsb
        pop     di
        pop     si
        je      .yes
        add     di, 4
        inc     al
        cmp     al, 3
        jb      .e
        stc
        ret
.yes:   clc
        ret

; try_dir: progpath = dirbuf, a '\' if needed, cmdname, and an
; extension unless one was typed. CF clear if such a file exists.
try_dir:
        mov     si, dirbuf
        mov     di, progpath
.d:     lodsb
        test    al, al
        jz      .d_end
        stosb
        jmp     .d
.d_end: cmp     di, progpath
        je      .name
        mov     al, [di - 1]
        cmp     al, '\'
        je      .name
        cmp     al, ':'
        je      .name
        mov     al, '\'
        stosb
.name:  mov     si, cmdname
.n:     lodsb
        stosb
        test    al, al
        jnz     .n
        dec     di                      ; on the 0, where an extension goes
        mov     al, [ext_type]
        cmp     al, 0FFh
        je      .each
        mov     [prog_type], al
        mov     dx, progpath
        jmp     exists
.each:  mov     [ext_at], di
        xor     bx, bx
.try:   mov     di, [ext_at]
        mov     si, bx
        shl     si, 2
        add     si, bx
        add     si, dot_exts            ; 5 bytes each: '.COM', 0
        mov     cx, 5
        rep     movsb
        push    bx
        mov     dx, progpath
        call    exists
        pop     bx
        jnc     .hit
        cmp     byte [crit_failed], 0   ; not .EXE and .BAT on a drive that failed
        jne     .miss
        inc     bx
        cmp     bx, 3
        jb      .try
.miss:  stc
        ret
.hit:   mov     [prog_type], bl
        clc
        ret

; exists: CF clear if the file at DX is there (a directory is not a file).
exists:
        xor     cx, cx
        mov     ah, 4Eh
        int     21h
        ret

; find_path: SI = the PATH value in our environment, CF set if there is none.
find_path:
        mov     ax, [PSP_ENV]
        test    ax, ax
        jz      .none
        push    ds
        mov     ds, ax
        xor     si, si
.var:   cmp     byte [si], 0
        je      .none_pop
        cmp     dword [si], 'PATH'
        jne     .skip
        cmp     byte [si + 4], '='
        jne     .skip
        add     si, 5
        pop     ds
        clc
        ret
.skip:  lodsb
        test    al, al
        jnz     .skip
        jmp     .var
.none_pop:
        pop     ds
.none:  stc
        ret

; run_program: EXEC progpath with the command tail in tailbuf.
run_program:
        ; Old programs read their first two arguments from the FCBs DOS
        ; copies into their PSP, so parse them as COMMAND.COM does.
        mov     si, tailbuf + 1
        mov     di, fcb1
        mov     ax, 2901h
        int     21h
        mov     di, fcb2
        mov     ax, 2901h
        int     21h

        mov     word [pb_env], 0        ; the child gets a copy of our environment
        mov     word [pb_tail], tailbuf
        mov     [pb_tail + 2], cs
        mov     word [pb_fcb1], fcb1
        mov     [pb_fcb1 + 2], cs
        mov     word [pb_fcb2], fcb2
        mov     [pb_fcb2 + 2], cs

        mov     [saved_sp], sp
        mov     byte [child_running], 1
        mov     dx, progpath
        mov     bx, param_block
        mov     ax, 4B00h
        int     21h
        cli                             ; only CS:IP is sure to survive EXEC
        mov     bx, cs
        mov     ss, bx
        mov     sp, [cs:saved_sp]
        sti
        mov     ds, bx
        mov     es, bx
        cld
        mov     byte [child_running], 0
        jc      .failed

        mov     ah, 4Dh                 ; AL = exit code, AH = how it ended
        int     21h
        mov     [errorlevel], al
        cmp     ah, 1                   ; ended by Ctrl-C
        jne     .done
        cmp     byte [batch_active], 0
        je      .done
        call    ask_terminate
.done:  ret

.failed:
        cmp     ax, 2
        je      bad_command
        mov     si, msg_no_memory
        cmp     ax, 8
        je      print_z
        mov     si, msg_bad_format
        cmp     ax, 11
        je      print_z
        push    ax
        mov     si, msg_exec_error
        call    print_z
        pop     ax
        call    put_dec
        mov     si, crlf
        jmp     print_z

; ------------------------------------------------------------
; Batch files
; ------------------------------------------------------------

; start_batch: progpath is a batch file; run it from its first line.
; Started from a batch file it replaces that one, as in DOS.
start_batch:
        mov     si, progpath            ; its full name, so a CD in it cannot lose it
        mov     di, batch_name
        mov     ah, 60h
        int     21h
        jnc     .named
        mov     si, progpath
        mov     di, batch_name
.copy:  lodsb
        stosb
        test    al, al
        jnz     .copy
.named: cmp     byte [batch_active], 0
        jne     .chained
        mov     byte [batch_echo], 1
.chained:
        mov     dword [batch_pos], 0
        mov     byte [batch_active], 1
        ret

; batch_next: read the next line of the batch file into linebuf.
; Out: CF clear and SI = the command to run, or CF set when there is
; nothing to run (a label, an empty line, the end of the file).
batch_next:
        mov     dx, batch_name
        mov     ax, 3D00h
        int     21h
        jc      .missing
        mov     bx, ax
        mov     dx, [batch_pos]
        mov     cx, [batch_pos + 2]
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
        jcxz    .end

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
.eol:   add     [batch_pos], dx
        adc     word [batch_pos + 2], 0
        jmp     .line
.eof:   mov     dword [batch_pos], 7FFFFFFFh  ; the next read finds nothing
.line:  mov     byte [di], 0

        mov     si, linebuf
        call    skip_blanks
        mov     al, [si]
        test    al, al
        jz      .skip
        cmp     al, ':'
        je      .skip
        mov     bl, [batch_echo]
        cmp     al, '@'
        jne     .echo
        xor     bl, bl
        inc     si
.echo:  test    bl, bl
        jz      .run
        push    si
        call    show_prompt
        pop     si
        push    si
        call    print_z
        mov     si, crlf
        call    print_z
        pop     si
.run:   clc
        ret
.missing:
        mov     si, msg_batch_missing
        call    print_z
.end:   mov     byte [batch_active], 0
.skip:  stc
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
        mov     si, crlf
        call    print_z
        pop     ax
        cmp     al, 'Y'
        jne     .done
        mov     byte [batch_active], 0
.done:  ret

; ------------------------------------------------------------
; Ctrl-C, critical errors, and the way back to the prompt
; ------------------------------------------------------------

; INT 23h. While a program runs it ends that program; at our own
; prompt or in our own DOS calls it abandons the line. DOS has left
; the interrupted call by now, so jumping away from it is allowed.
on_break:
        cmp     byte [cs:child_running], 0
        je      restart
        stc                             ; RETF with CF set, the flags left on the
        retf                            ; stack: DOS ends the program

; The way back to a clean prompt: from Ctrl-C, and through INT 22h
; when DOS "ends" the permanent shell after an Abort.
restart:
        cli
        mov     ax, cs
        mov     ss, ax
        mov     sp, stack_top
        sti
        mov     ds, ax
        mov     es, ax
        cld
        mov     byte [child_running], 0
        mov     dx, dta
        mov     ah, 1Ah
        int     21h
        cmp     byte [batch_active], 0
        je      main_loop
        call    ask_terminate
        jmp     main_loop

; INT 24h, a critical error: say what failed and ask what to do.
; AH bits: 0 writing, 3 Fail allowed, 4 Retry, 5 Ignore, 7 not a disk.
; AL = drive, DI = error code, BP:SI = the device header.
; Only INT 21h functions 01h to 0Ch may be used in here.
on_critical:
        sti
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        push    cs
        pop     ds
        mov     [crit_flags], ah
        mov     [crit_drive], al
        mov     [crit_dev], si
        mov     [crit_dev + 2], bp

        mov     si, crlf
        call    con_z
        mov     bx, di
        and     bx, 0FFh
        cmp     bx, 12
        jbe     .known
        mov     bx, 12
.known: shl     bx, 1
        mov     si, [crit_msgs + bx]
        call    con_z
        test    byte [crit_flags], 80h
        jnz     .device
        mov     si, msg_reading
        test    byte [crit_flags], 1
        jz      .rw
        mov     si, msg_writing
.rw:    call    con_z
        mov     dl, [crit_drive]
        add     dl, 'A'
        call    con_c
        jmp     .ask
.device:
        mov     si, msg_device
        call    con_z
        push    ds
        lds     si, [crit_dev]
        add     si, 0Ah                 ; the device name, 8 characters
        mov     cx, 8
.dn:    lodsb
        cmp     al, ' '
        je      .dn_end
        mov     dl, al
        call    con_c
        loop    .dn
.dn_end:
        pop     ds

.ask:   mov     si, crlf
        call    con_z
        mov     si, opt_abort
        call    con_z
        test    byte [crit_flags], 10h
        jz      .no_retry
        mov     si, opt_retry
        call    con_z
.no_retry:
        test    byte [crit_flags], 20h
        jz      .no_ignore
        mov     si, opt_ignore
        call    con_z
.no_ignore:
        test    byte [crit_flags], 08h
        jz      .question
        mov     si, opt_fail
        call    con_z
.question:
        mov     si, opt_end
        call    con_z

.key:   mov     ah, 07h
        int     21h
        call    upcase
        mov     bl, al
        mov     bh, 2
        cmp     al, 'A'
        je      .chosen
        mov     bh, 1
        cmp     al, 'R'
        jne     .not_r
        test    byte [crit_flags], 10h
        jnz     .chosen
.not_r: xor     bh, bh
        cmp     al, 'I'
        jne     .not_i
        test    byte [crit_flags], 20h
        jnz     .chosen
.not_i: mov     bh, 3
        cmp     al, 'F'
        jne     .key
        test    byte [crit_flags], 08h
        jz      .key
.chosen:
        mov     dl, bl
        call    con_c
        mov     si, crlf
        call    con_z
        ; Abort ends the running program. With none running it would end
        ; the shell itself, so give the error back to our own call instead.
        cmp     bh, 2
        jne     .answer
        cmp     byte [child_running], 0
        jne     .answer
        mov     bh, 3
        test    byte [crit_flags], 08h
        jnz     .answer
        xor     bh, bh
        test    byte [crit_flags], 20h
        jnz     .answer
        mov     bh, 2                   ; nothing else allowed: a permanent shell
                                        ; comes back through INT 22h
.answer:
        cmp     byte [child_running], 0 ; our own call failed: let the shell know
        jne     .give
        cmp     bh, 3
        jne     .give
        mov     byte [crit_failed], 1
.give:
        mov     al, bh
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        iret

; ------------------------------------------------------------
; Start-up
; ------------------------------------------------------------

; parse_switches: read our own command tail.
parse_switches:
        movzx   cx, byte [PSP_TAIL]
        mov     si, PSP_TAIL + 1
        mov     di, switches
.copy:  jcxz    .copied
        lodsb
        cmp     al, 13
        je      .copied
        stosb
        dec     cx
        jmp     .copy
.copied:
        mov     byte [di], 0
        mov     si, switches
.next:  call    skip_blanks
        lodsb
        test    al, al
        jz      .done
        cmp     al, '/'
        jne     .skip_word
        lodsb
        call    upcase
        cmp     al, 'C'
        je      .oneshot
        cmp     al, 'K'
        je      .oneshot
        cmp     al, 'D'
        je      .d
        cmp     al, 'P'
        jne     .skip_word
        mov     byte [permanent], 1
        mov     byte [want_startup], 1
        cmp     byte [si], '='
        jne     .next
        inc     si
        mov     di, startup_name
.name:  lodsb
        cmp     al, ' '
        jbe     .name_end
        cmp     al, '/'
        je      .name_end
        cmp     di, startup_name + NAME_MAX
        jae     .name
        stosb
        jmp     .name
.name_end:
        dec     si
        mov     byte [di], 0
        jmp     .next
.d:     mov     byte [no_startup], 1
        jmp     .skip_word
.oneshot:
        mov     [mode], al              ; the rest of the line is the command
        call    skip_blanks
        mov     [oneshot], si
.done:  ret
.skip_word:                             ; a directory, /E:n, anything else
        mov     al, [si]
        cmp     al, ' '
        jbe     .next
        cmp     al, '/'
        je      .next
        inc     si
        jmp     .skip_word

; check_root: were we started by DOS itself (SHELL=) rather than by a
; program? Then nothing is there to go back to, and we are permanent
; even without /P. A program's PSP sits right after its memory block's
; arena header, which names it as the owner; DOS's own PSP has none.
check_root:
        mov     ax, [PSP_PARENT]
        mov     bx, cs
        cmp     ax, bx
        je      .root
        dec     ax
        mov     es, ax
        mov     dl, [es:0]
        cmp     dl, 'M'
        je      .arena
        cmp     dl, 'Z'
        jne     .root
.arena: inc     ax
        cmp     [es:1], ax
        jne     .root
        push    cs
        pop     es
        ret
.root:  push    cs
        pop     es
        mov     byte [by_dos], 1
        mov     byte [permanent], 1
        ret

banner:
        mov     si, msg_banner
        call    print_z
        mov     ah, 30h                 ; AL = major, AH = minor, BH = OEM number
        int     21h
        push    bx
        push    ax
        movzx   ax, al
        call    put_dec
        mov     dl, '.'
        call    putc
        pop     ax
        movzx   ax, ah
        cmp     ax, 10
        jae     .minor
        push    ax
        mov     dl, '0'
        call    putc
        pop     ax
.minor: call    put_dec
        mov     si, msg_oem
        call    print_z
        pop     bx
        mov     al, bh
        call    put_hex8
        mov     si, msg_by_program
        cmp     byte [by_dos], 0
        je      .by
        mov     si, msg_by_dos
.by:    call    print_z
        cmp     byte [permanent], 0
        je      .end
        mov     si, msg_permanent
        call    print_z
.end:   mov     si, crlf
        jmp     print_z

; ------------------------------------------------------------
; Small helpers
; ------------------------------------------------------------

; skip_blanks: SI past spaces, tabs and line feeds.
skip_blanks:
        mov     al, [si]
        cmp     al, ' '
        je      .skip
        cmp     al, 9
        je      .skip
        cmp     al, 10
        jne     .done
.skip:  inc     si
        jmp     skip_blanks
.done:  ret

; is_delim: ZF set if AL ends a command name.
is_delim:
        push    cx
        push    di
        mov     di, delims
        mov     cx, delims_end - delims
        repne   scasb
        pop     di
        pop     cx
        ret

upcase:
        cmp     al, 'a'
        jb      .done
        cmp     al, 'z'
        ja      .done
        sub     al, 20h
.done:  ret

; print_z: SI = ASCIIZ string, to standard output.
print_z:
        push    ax
        push    bx
        push    cx
        push    dx
        push    di
        mov     di, si
        xor     al, al
        mov     cx, 0FFFFh
        repne   scasb
        not     cx
        dec     cx
        mov     dx, si
        mov     bx, 1
        mov     ah, 40h
        int     21h
        pop     di
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; DL = character
putc:
        mov     ah, 02h
        int     21h
        ret

; The same for the critical error handler, which may not use AH=40h.
con_z:  lodsb
        test    al, al
        jz      .done
        mov     dl, al
        call    con_c
        jmp     con_z
.done:  ret

con_c:  mov     ah, 02h
        int     21h
        ret

; AX = number, printed in decimal
put_dec:
        mov     bx, 10
        xor     cx, cx
.div:   xor     dx, dx
        div     bx
        push    dx
        inc     cx
        test    ax, ax
        jnz     .div
.out:   pop     dx
        add     dl, '0'
        call    putc
        loop    .out
        ret

; AL = byte, printed as two hex digits
put_hex8:
        push    ax
        shr     al, 4
        call    .nibble
        pop     ax
        and     al, 0Fh
.nibble:
        add     al, '0'
        cmp     al, '9'
        jbe     .digit
        add     al, 7
.digit: mov     dl, al
        jmp     putc

; ------------------------------------------------------------
; Data
; ------------------------------------------------------------

msg_banner      db 'Claude shell for DOS - phase 1 (386 real mode)', 13, 10
                db 'DOS ', 0
msg_oem         db ', OEM ', 0
msg_by_dos      db ', started by DOS', 0
msg_by_program  db ', started by a program', 0
msg_permanent   db ', permanent', 0
msg_bad_command db 'Bad command or file name', 13, 10, 0
msg_bad_drive   db 'Invalid drive specification', 13, 10, 0
msg_no_memory   db 'Not enough memory to run the program', 13, 10, 0
msg_bad_format  db 'Not a program DOS can load', 13, 10, 0
msg_exec_error  db 'Cannot run the program: DOS error ', 0
msg_batch_missing db 'Batch file missing', 13, 10, 0
msg_terminate   db 'Terminate batch job (Y/N)? ', 0
crlf            db 13, 10, 0

msg_reading     db ' reading drive ', 0
msg_writing     db ' writing drive ', 0
msg_device      db ' on device ', 0
opt_abort       db 'Abort', 0
opt_retry       db ', Retry', 0
opt_ignore      db ', Ignore', 0
opt_fail        db ', Fail', 0
opt_end         db '? ', 0
crit_msgs       dw ce0, ce1, ce2, ce3, ce4, ce5, ce6, ce7, ce8, ce9, ce10, ce11, ce12
ce0             db 'Write protect error', 0
ce1             db 'Unknown unit', 0
ce2             db 'Not ready', 0
ce3             db 'Unknown command', 0
ce4             db 'Data error', 0
ce5             db 'Bad request structure length', 0
ce6             db 'Seek error', 0
ce7             db 'Unknown media type', 0
ce8             db 'Sector not found', 0
ce9             db 'Printer out of paper', 0
ce10            db 'Write fault', 0
ce11            db 'Read fault', 0
ce12            db 'General failure', 0

name_exit       db 'EXIT', 0
name_rem        db 'REM', 0
default_startup db '\AUTOEXEC.BAT', 0
exts            db 'COM', 0, 'EXE', 0, 'BAT', 0
dot_exts        db '.COM', 0, '.EXE', 0, '.BAT', 0
delims          db 0, ' ', 9, 10, 13, '/', '<', '>', '|', '=', ',', ';', '+', '"'
delims_end:

; ------------------------------------------------------------
; Uninitialised data, cleared at start-up; the stack is last.
; ------------------------------------------------------------
        section .bss
bss_start:
permanent       resb 1
want_startup    resb 1
no_startup      resb 1
by_dos          resb 1
mode            resb 1          ; 0, 'C' or 'K'
exit_after      resb 1
no_blank        resb 1
child_running   resb 1
errorlevel      resb 1
has_path        resb 1
ext_type        resb 1
prog_type       resb 1
batch_active    resb 1
batch_echo      resb 1
crit_flags      resb 1
crit_drive      resb 1
crit_failed     resb 1          ; a critical error in our own call was answered Fail
                alignb 4
crit_dev        resd 1
batch_pos       resd 1
oneshot         resw 1
cmd_start       resw 1
tok_end         resw 1
path_pos        resw 1
ext_at          resw 1
saved_sp        resw 1

param_block:
pb_env          resw 1
pb_tail         resd 1
pb_fcb1         resd 1
pb_fcb2         resd 1

switches        resb 130
startup_name    resb NAME_MAX + 2
inbuf           resb LINE_MAX + 4
linebuf         resb LINE_MAX + 2
cmdname         resb NAME_MAX + 2
dirbuf          resb NAME_MAX + 2
progpath        resb 2 * NAME_MAX + 8
tailbuf         resb LINE_MAX + 4
batch_name      resb 130
cwdbuf          resb NAME_MAX + 8
dta             resb 44
fcb1            resb 37
fcb2            resb 37
BATCHBUF_SIZE   equ 256
batchbuf        resb BATCHBUF_SIZE
                alignb 2
                resb 1024
stack_top:
bss_end:
