; ============================================================
; cmds.asm - the internal commands, apart from DIR and COPY.
; Each is entered with SI on what follows its name and returns
; to the shell's loop. Messages follow MS-DOS 6.22's wording.
; ============================================================
        section .text

required_missing:
        mov     si, msg_required
        jmp     print_err

invalid_parameter:
        mov     si, msg_invalid_param
        jmp     print_err

; ECHO [ON | OFF | text]   ECHO. prints an empty line
cmd_echo:
        mov     al, [si]
        test    al, al
        jz      .state
        inc     si                      ; the character after ECHO is not printed
        cmp     al, '.'
        je      .text
        cmp     al, ':'
        je      .text
        cmp     al, '('
        je      .text
        cmp     al, '['
        je      .text
        push    si
        call    skip_blanks
        cmp     byte [si], 0
        pop     si
        je      .state
        push    si
        call    parse_onoff
        pop     si
        jc      .text
        mov     [echo_on], al
        ret
.text:  call    print_z
        jmp     newline
.state: mov     si, msg_echo_is_on
        cmp     byte [echo_on], 0
        jne     .say
        mov     si, msg_echo_is_off
.say:   jmp     print_z

; SET [name=[value]]
cmd_set:
        call    skip_blanks
        cmp     byte [si], 0
        je      env_list
        mov     di, namebuf
        mov     cx, NAME_MAX
.n:     lodsb
        test    al, al
        jz      .syntax
        cmp     al, '='
        je      .value
        call    upcase
        stosb
        loop    .n
.syntax:
        mov     si, msg_syntax
        jmp     print_err
.value: cmp     di, namebuf
        je      .syntax
        mov     byte [di], 0
        mov     bx, si
        mov     si, namebuf
        jmp     env_set

; PATH [dir;dir...]   PATH ; clears it
cmd_path:
        call    skip_eq
        cmp     byte [si], 0
        je      .show
        cmp     byte [si], ';'
        jne     .set
        push    si
        inc     si
        call    skip_blanks
        cmp     byte [si], 0
        pop     si
        jne     .set
        mov     bx, empty_str
        jmp     .store
.set:   mov     di, valbuf
.up:    lodsb
        call    upcase
        stosb
        test    al, al
        jnz     .up
        dec     di
.trim:  cmp     di, valbuf
        je      .trimmed
        cmp     byte [di - 1], ' '
        je      .back
        cmp     byte [di - 1], 9
        jne     .trimmed
.back:  dec     di
        jmp     .trim
.trimmed:
        mov     byte [di], 0
        mov     bx, valbuf
.store: mov     si, name_path
        jmp     env_set
.show:  mov     si, name_path
        mov     di, valbuf
        mov     cx, VALBUF_SIZE - 1
        call    env_get
        jc      .none
        cmp     byte [valbuf], 0
        je      .none
        mov     si, msg_path_is
        call    print_z
        mov     si, valbuf
        call    print_z
        jmp     newline
.none:  mov     si, msg_no_path
        jmp     print_z

; PROMPT [text]   no text: back to the default, $P$G
cmd_prompt:
        call    skip_eq
        mov     bx, si
        mov     si, name_prompt
        jmp     env_set

; skip_eq: SI past blanks and one '=' (PATH=..., PROMPT=...).
skip_eq:
        call    skip_blanks
        cmp     byte [si], '='
        jne     .done
        inc     si
        call    skip_blanks
.done:  ret

; CD [drive:][path]   CHDIR
cmd_cd:
        call    parse_args
        xor     al, al
        cmp     word [argc], 0
        je      .show
        mov     si, [argv]
        cmp     byte [si + 1], ':'      ; X: alone shows that drive's directory
        jne     .chdir
        cmp     byte [si + 2], 0
        jne     .chdir
        mov     al, [si]
        call    upcase
        sub     al, 'A' - 1
.show:  call    print_cwd
        jc      .bad_drive
        jmp     newline
.chdir: mov     dx, si
        mov     ah, 3Bh
        int     21h
        jnc     .done
        mov     si, msg_bad_dir
        jmp     print_err
.bad_drive:
        mov     si, msg_bad_drive
        jmp     print_err
.done:  ret

; print_cwd: "X:\PATH" for drive AL (1 = A:, 0 = the current one).
; CF if the drive is not there.
print_cwd:
        test    al, al
        jnz     .known
        mov     ah, 19h
        int     21h
        inc     al
.known: mov     [cwd_drive], al
        add     al, 'A' - 1
        mov     [cwdbuf], al
        mov     byte [cwdbuf + 1], ':'
        mov     byte [cwdbuf + 2], '\'
        mov     si, cwdbuf + 3
        mov     dl, [cwd_drive]
        mov     ah, 47h
        int     21h
        jnc     .show
        mov     byte [cwdbuf + 3], 0
        cmp     ax, 15                  ; no such drive
        jne     .show
        stc
        ret
.show:  mov     si, cwdbuf
        call    print_z
        clc
        ret

; MD path   MKDIR
cmd_md:
        call    parse_args
        cmp     word [argc], 0
        je      required_missing
        mov     dx, [argv]
        mov     ah, 39h
        int     21h
        jnc     .done
        mov     si, msg_md_failed
        jmp     print_err
.done:  ret

; RD path   RMDIR
cmd_rd:
        call    parse_args
        cmp     word [argc], 0
        je      required_missing
        mov     dx, [argv]
        mov     ah, 3Ah
        int     21h
        jnc     .done
        mov     si, msg_rd_failed
        jmp     print_err
.done:  ret

; DEL files   ERASE. A directory, or *.*, deletes all its files after asking.
cmd_del:
        call    parse_args
        cmp     word [argc], 0
        je      required_missing
        mov     si, [argv]
        mov     di, patbuf
        xor     bl, bl
        call    make_pattern
        mov     si, patbuf
        mov     di, dirpart
        call    dir_prefix
        mov     [name_at], di
        ; all of a directory? (the name part is all wildcards)
        mov     si, patbuf
        call    last_component
        mov     si, bx
        mov     di, fcb_t
        mov     ax, 2900h
        int     21h
        mov     di, fcb_t + 1
        mov     al, '?'
        mov     cx, 11
        repe    scasb
        jne     .search
        mov     si, msg_del_all
        call    print_z
        mov     di, ansbuf
        call    read_line
        mov     al, [ansbuf]
        call    upcase
        cmp     al, 'Y'
        jne     .done
.search:
        mov     dx, dta
        mov     ah, 1Ah
        int     21h
        xor     cx, cx
        mov     dx, patbuf
        mov     ah, 4Eh
        int     21h
        jnc     .each
        mov     si, msg_file_not_found
        jmp     print_err
.each:  mov     di, [name_at]
        mov     si, dta + 1Eh
        call    append_z
        mov     dx, dirpart
        mov     ah, 41h
        int     21h
        jnc     .next
        mov     si, dirpart
        call    print_z
        mov     si, msg_dash
        call    print_z
        call    print_dos_error
.next:  mov     ah, 4Fh
        int     21h
        jnc     .each
.done:  ret

; REN old new   RENAME. The new name has no path and may use wildcards.
cmd_ren:
        call    parse_args
        cmp     word [argc], 2
        jb      required_missing
        mov     si, [argv + 2]
.check: lodsb
        test    al, al
        jz      .ok
        cmp     al, ':'
        je      invalid_parameter
        cmp     al, '\'
        je      invalid_parameter
        jmp     .check
.ok:    mov     si, [argv]
        mov     di, dirpart
        call    dir_prefix
        mov     [name_at], di
        mov     si, [argv]
        mov     di, pathbuf
        call    dir_prefix
        mov     [new_at], di
        mov     dx, dta
        mov     ah, 1Ah
        int     21h
        xor     cx, cx
        mov     dx, [argv]
        mov     ah, 4Eh
        int     21h
        jnc     .each
        mov     si, msg_file_not_found
        jmp     print_err
.each:  mov     di, [name_at]
        mov     si, dta + 1Eh
        call    append_z
        mov     di, [new_at]
        mov     si, dta + 1Eh
        mov     bx, [argv + 2]
        call    apply_template
        mov     dx, dirpart
        mov     di, pathbuf
        mov     ah, 56h
        int     21h
        jnc     .next
        mov     si, msg_ren_failed
        call    print_err
.next:  mov     ah, 4Fh
        int     21h
        jnc     .each
        ret

; TYPE file: its text, up to a ^Z.
cmd_type:
        call    parse_args
        cmp     word [argc], 0
        je      required_missing
        mov     si, [argv]
        call    has_wild
        jc      invalid_parameter
        mov     dx, si
        mov     ax, 3D00h
        int     21h
        jnc     .open
        jmp     print_dos_error
.open:  mov     [h_src], ax
.read:  mov     bx, [h_src]
        mov     dx, iobuf
        mov     cx, IOBUF_SIZE
        mov     ah, 3Fh
        int     21h
        jc      .close
        test    ax, ax
        jz      .close
        mov     cx, ax
        push    cx
        mov     di, iobuf
        mov     al, 1Ah
        repne   scasb
        pop     cx
        mov     byte [type_stop], 0
        jne     .write
        mov     cx, di                  ; a ^Z: write what comes before it, then stop
        sub     cx, iobuf + 1
        mov     byte [type_stop], 1
.write: mov     dx, iobuf
        mov     bx, 1
        mov     ah, 40h
        int     21h
        cmp     byte [type_stop], 0
        je      .read
.close: mov     bx, [h_src]
        mov     ah, 3Eh
        int     21h
        ret

; CLS: clear the screen through the BIOS, in the current colours.
cmd_cls:
        mov     ah, 0Fh                 ; AH = columns, BH = page
        int     10h
        mov     [cls_page], bh
        mov     dl, ah
        dec     dl
        push    es
        push    word 40h
        pop     es
        mov     dh, [es:84h]            ; rows less one, where the BIOS keeps it
        pop     es
        test    dh, dh
        jnz     .rows
        mov     dh, 24
.rows:  mov     ax, 0600h
        mov     bh, 07h
        xor     cx, cx
        int     10h
        mov     ah, 02h
        mov     bh, [cls_page]
        xor     dx, dx
        int     10h
        ret

; VER
cmd_ver:
        mov     si, msg_banner
        call    print_z
        call    print_dos_version
        jmp     newline

; print_dos_version: "7.10, OEM FD"
print_dos_version:
        mov     ah, 30h                 ; AL = major, AH = minor, BH = OEM number
        int     21h
        mov     [ver_oem], bh
        mov     [ver_minor], ah
        movzx   ax, al
        call    put_dec
        mov     dl, '.'
        call    putc
        mov     al, [ver_minor]
        call    put2
        mov     si, msg_oem
        call    print_z
        mov     al, [ver_oem]
        jmp     put_hex8

; VOL [drive:]
cmd_vol:
        call    parse_args
        cmp     word [argc], 0
        je      .current
        mov     si, [argv]
        cmp     byte [si + 1], ':'
        jne     invalid_parameter
        mov     al, [si]
        call    upcase
        sub     al, 'A' - 1
        jmp     print_volume
.current:
        mov     ah, 19h
        int     21h
        inc     al
        ; fall through

; print_volume: the volume lines for drive AL (1 = A:), as DIR starts.
print_volume:
        mov     [vol_drive], al
        mov     dx, dta
        mov     ah, 1Ah
        int     21h
        mov     al, [vol_drive]
        add     al, 'A' - 1
        mov     [volpat], al
        mov     si, msg_volume_in
        call    print_z
        mov     dl, [volpat]
        call    putc
        mov     dword [volpat + 1], ':\*.'
        mov     word [volpat + 5], '*'
        mov     cx, 08h                 ; the volume label only
        mov     dx, volpat
        mov     ah, 4Eh
        int     21h
        jc      .no_label
        test    byte [dta + 15h], 08h
        jz      .no_label
        mov     si, msg_is
        call    print_z
        mov     si, dta + 1Eh           ; a label of 9 or more shows a dot DOS put in
.label: lodsb
        test    al, al
        jz      .labelled
        cmp     al, '.'
        je      .label
        mov     dl, al
        call    putc
        jmp     .label
.no_label:
        mov     si, msg_no_label
        call    print_z
.labelled:
        call    newline
        mov     ax, 6900h               ; the serial number, DOS 4 and later
        mov     bl, [vol_drive]
        xor     bh, bh
        mov     dx, serbuf
        int     21h
        jc      .done
        mov     si, msg_serial
        call    print_z
        mov     ax, [serbuf + 4]
        call    put_hex16
        mov     dl, '-'
        call    putc
        mov     ax, [serbuf + 2]
        call    put_hex16
        call    newline
.done:  ret

; DATE [mm-dd-yy]
cmd_date:
        call    skip_blanks
        cmp     byte [si], 0
        jne     .given
        mov     si, msg_date_now
        call    print_z
        call    print_date
        call    newline
.ask:   mov     si, msg_date_new
        call    print_z
        mov     di, ansbuf
        call    read_line
        mov     si, ansbuf
        call    skip_blanks
        cmp     byte [si], 0
        je      .done
.given: call    set_date
        jnc     .done
        mov     si, msg_bad_date
        call    print_err
        jmp     .ask
.done:  ret

; set_date: month-day-year at SI ('-', '/' or '.' between); CF if invalid.
set_date:
        call    parse_num
        jc      .bad
        mov     [dt_month], al
        call    date_sep
        jc      .bad
        call    parse_num
        jc      .bad
        mov     [dt_day], al
        call    date_sep
        jc      .bad
        call    parse_num
        jc      .bad
        cmp     ax, 100
        jae     .year
        add     ax, 1900
        cmp     ax, 1980
        jae     .year
        add     ax, 100
.year:  mov     cx, ax
        mov     dh, [dt_month]
        mov     dl, [dt_day]
        mov     ah, 2Bh
        int     21h
        test    al, al
        jnz     .bad
        clc
        ret
.bad:   stc
        ret

date_sep:
        mov     al, [si]
        cmp     al, '-'
        je      .ok
        cmp     al, '/'
        je      .ok
        cmp     al, '.'
        je      .ok
        stc
        ret
.ok:    inc     si
        clc
        ret

; TIME [hh[:mm[:ss[.cc]]][a|p]]
cmd_time:
        call    skip_blanks
        cmp     byte [si], 0
        jne     .given
        mov     si, msg_time_now
        call    print_z
        mov     bl, 1
        call    print_time
        call    newline
.ask:   mov     si, msg_time_new
        call    print_z
        mov     di, ansbuf
        call    read_line
        mov     si, ansbuf
        call    skip_blanks
        cmp     byte [si], 0
        je      .done
.given: call    set_time
        jnc     .done
        mov     si, msg_bad_time
        call    print_err
        jmp     .ask
.done:  ret

set_time:
        mov     dword [tm_parts], 0
        call    parse_num
        jc      .bad
        mov     [tm_parts], al
        cmp     byte [si], ':'
        jne     .ampm
        inc     si
        call    parse_num
        jc      .bad
        mov     [tm_parts + 1], al
        cmp     byte [si], ':'
        jne     .ampm
        inc     si
        call    parse_num
        jc      .bad
        mov     [tm_parts + 2], al
        cmp     byte [si], '.'
        jne     .ampm
        inc     si
        call    parse_num
        jc      .bad
        mov     [tm_parts + 3], al
.ampm:  call    skip_blanks
        mov     al, [si]
        call    upcase
        mov     ah, [tm_parts]
        cmp     al, 'A'
        jne     .pm
        cmp     ah, 12
        jne     .set
        mov     byte [tm_parts], 0
        jmp     .set
.pm:    cmp     al, 'P'
        jne     .set
        cmp     ah, 12
        jae     .set
        add     byte [tm_parts], 12
.set:   mov     ch, [tm_parts]
        mov     cl, [tm_parts + 1]
        mov     dh, [tm_parts + 2]
        mov     dl, [tm_parts + 3]
        mov     ah, 2Dh
        int     21h
        test    al, al
        jnz     .bad
        clc
        ret
.bad:   stc
        ret

; BREAK [ON | OFF]
cmd_break:
        call    parse_onoff
        jc      .bad
        cmp     al, 2
        je      .show
        mov     dl, al
        mov     ax, 3301h
        int     21h
        ret
.show:  mov     ax, 3300h
        int     21h
        mov     si, msg_break_on
        test    dl, dl
        jnz     .say
        mov     si, msg_break_off
.say:   jmp     print_z
.bad:   mov     si, msg_on_or_off
        jmp     print_err

; VERIFY [ON | OFF]
cmd_verify:
        call    parse_onoff
        jc      cmd_break.bad
        cmp     al, 2
        je      .show
        xor     dl, dl
        mov     ah, 2Eh
        int     21h
        ret
.show:  mov     ah, 54h
        int     21h
        mov     si, msg_verify_on
        test    al, al
        jnz     .say
        mov     si, msg_verify_off
.say:   jmp     print_z

; TRUENAME [path]
cmd_truename:
        call    parse_args
        mov     si, dot_str
        cmp     word [argc], 0
        je      .name
        mov     si, [argv]
.name:  mov     di, pathbuf
        call    truename
        jnc     .show
        jmp     print_dos_error
.show:  mov     si, pathbuf
        call    print_z
        jmp     newline

; PAUSE
cmd_pause:
        mov     si, msg_pause
        call    print_z
        mov     ah, 08h
        int     21h
        jmp     newline

; LH [/L:...] [/S] program   LOADHIGH: no upper memory here, so just run it.
cmd_lh:
        call    skip_blanks
        cmp     byte [si], '/'
        jne     .run
.skip:  inc     si
        mov     al, [si]
        test    al, al
        jz      .run
        cmp     al, ' '
        jne     .skip
        jmp     cmd_lh
.run:   jmp     execute_line

        section .data
msg_required    db 'Required parameter missing', 13, 10, 0
msg_invalid_param db 'Invalid parameter', 13, 10, 0
msg_syntax      db 'Syntax error', 13, 10, 0
msg_echo_is_on  db 'ECHO is on', 13, 10, 0
msg_echo_is_off db 'ECHO is off', 13, 10, 0
msg_path_is     db 'PATH=', 0
msg_no_path     db 'No Path', 13, 10, 0
msg_bad_dir     db 'Invalid directory', 13, 10, 0
msg_md_failed   db 'Unable to create directory', 13, 10, 0
msg_rd_failed   db 'Invalid path, not directory,', 13, 10, 'or directory not empty', 13, 10, 0
msg_del_all     db 'All files in directory will be deleted!', 13, 10, 'Are you sure (Y/N)?', 0
msg_dash        db ' - ', 0
msg_ren_failed  db 'Duplicate file name or file not found', 13, 10, 0
msg_volume_in   db ' Volume in drive ', 0
msg_is          db ' is ', 0
msg_no_label    db ' has no label', 0
msg_serial      db ' Volume Serial Number is ', 0
msg_date_now    db 'Current date is ', 0
msg_date_new    db 'Enter new date (mm-dd-yy): ', 0
msg_bad_date    db 'Invalid date', 13, 10, 0
msg_time_now    db 'Current time is ', 0
msg_time_new    db 'Enter new time: ', 0
msg_bad_time    db 'Invalid time', 13, 10, 0
msg_break_on    db 'BREAK is on', 13, 10, 0
msg_break_off   db 'BREAK is off', 13, 10, 0
msg_verify_on   db 'VERIFY is on', 13, 10, 0
msg_verify_off  db 'VERIFY is off', 13, 10, 0
msg_on_or_off   db 'Must specify ON or OFF', 13, 10, 0
msg_pause       db 'Press any key to continue . . .', 0
dot_str         db '.', 0
empty_str       db 0

        section .bss
VALBUF_SIZE     equ 130
IOBUF_SIZE      equ 512
namebuf         resb NAME_MAX + 2
valbuf          resb VALBUF_SIZE
ansbuf          resb LINE_MAX + 4
patbuf          resb 2 * NAME_MAX + 8
dirpart         resb 2 * NAME_MAX + 16
pathbuf         resb 2 * NAME_MAX + 16
cwdbuf          resb NAME_MAX + 8
volpat          resb 8
serbuf          resb 26
iobuf           resb IOBUF_SIZE
name_at         resw 1
new_at          resw 1
h_src           resw 1
h_dst           resw 1
cwd_drive       resb 1
vol_drive       resb 1
cls_page        resb 1
type_stop       resb 1
ver_oem         resb 1
ver_minor       resb 1
                alignb 4
tm_parts        resb 4
