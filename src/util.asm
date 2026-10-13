; ============================================================
; util.asm - helpers shared by the shell and its commands:
; scanning text, splitting arguments, printing strings and
; numbers, dates and times, and file name patterns.
; ============================================================
        section .text

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

; is_sep: ZF set if AL ends an argument.
is_sep:
        push    cx
        push    di
        mov     di, seps
        mov     cx, seps_end - seps
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

; strlen: AX = length of the ASCIIZ string at DS:SI.
strlen:
        push    si
        xor     ax, ax
.l:     cmp     byte [si], 0
        je      .done
        inc     si
        inc     ax
        jmp     .l
.done:  pop     si
        ret

; append_z: copy the ASCIIZ string at DS:SI to ES:DI; DI ends on the new 0.
append_z:
        lodsb
        stosb
        test    al, al
        jnz     append_z
        dec     di
        ret

; parse_args: split the arguments at SI into words and switches.
; Out: argc, argv[] (pointers to ASCIIZ copies in argbuf), and the
; switches as bits of a dword: bit 0 for /A up to bit 25 for /Z.
; "DIR/W/P C:\" gives one word and two switches. A switch's own value
; (/A:H) is skipped.
parse_args:
        mov     word [argc], 0
        mov     dword [switches], 0
        mov     di, argbuf
.next:  call    skip_seps
        mov     al, [si]
        test    al, al
        jz      .done
        cmp     al, '/'
        jne     .word
        inc     si
        lodsb
        call    upcase
        cmp     al, 'A'
        jb      .skip_switch
        cmp     al, 'Z'
        ja      .skip_switch
        sub     al, 'A'
        movzx   eax, al
        bts     [switches], eax
.skip_switch:
        mov     al, [si]
        cmp     al, '/'
        je      .next
        call    is_sep
        je      .next
        inc     si
        jmp     .skip_switch
.word:  mov     bx, [argc]
        cmp     bx, MAX_ARGS
        jae     .copy                   ; too many: read past it
        shl     bx, 1
        mov     [argv + bx], di
        inc     word [argc]
.copy:  mov     al, [si]
        cmp     al, '/'
        je      .word_end
        call    is_sep
        je      .word_end
        stosb
        inc     si
        jmp     .copy
.word_end:
        mov     byte [di], 0
        inc     di
        jmp     .next
.done:  ret

; skip_seps: SI past blanks and the separators DOS also allows between
; arguments: , ; =
skip_seps:
        mov     al, [si]
        cmp     al, ' '
        je      .skip
        cmp     al, 9
        je      .skip
        cmp     al, 10
        je      .skip
        cmp     al, ','
        je      .skip
        cmp     al, ';'
        je      .skip
        cmp     al, '='
        jne     .done
.skip:  inc     si
        jmp     skip_seps
.done:  ret

; parse_num: a decimal number at SI. Out: AX, SI past it; CF if no digit.
parse_num:
        xor     ax, ax
        xor     cx, cx
.d:     movzx   bx, byte [si]
        sub     bl, '0'
        cmp     bl, 9
        ja      .end
        imul    ax, ax, 10
        add     ax, bx
        inc     si
        inc     cx
        jmp     .d
.end:   test    cx, cx
        jz      .none
        clc
        ret
.none:  stc
        ret

; parse_onoff: ON, OFF or nothing at SI (blanks around are fine).
; Out: AL = 1 for ON, 0 for OFF, 2 for nothing; CF if it is anything else.
parse_onoff:
        call    skip_blanks
        mov     al, 2
        cmp     byte [si], 0
        je      .ok
        mov     ax, [si]
        and     ax, 0DFDFh              ; upper case both letters
        cmp     ax, 'ON'
        jne     .off
        add     si, 2
        mov     ah, 1
        jmp     .tail
.off:   cmp     ax, 'OF'
        jne     .bad
        mov     al, [si + 2]
        and     al, 0DFh
        cmp     al, 'F'
        jne     .bad
        add     si, 3
        mov     ah, 0
.tail:  push    ax
        call    skip_blanks
        pop     ax
        cmp     byte [si], 0
        jne     .bad
        mov     al, ah
.ok:    clc
        ret
.bad:   stc
        ret

; ------------------------------------------------------------
; Output
; ------------------------------------------------------------

; print_err: SI = ASCIIZ string, to standard error, where COMMAND.COM
; and FreeCOM both put their error messages.
print_err:
        mov     byte [out_handle], 2
        call    print_z
        mov     byte [out_handle], 1
        ret

; print_z: SI = ASCIIZ string, to standard output (or out_handle).
print_z:
        push    ax
        push    bx
        push    cx
        push    dx
        call    strlen
        mov     cx, ax
        mov     dx, si
        movzx   bx, byte [cs:out_handle] ; DS may be elsewhere (SET lists from the environment)
        mov     ah, 40h
        int     21h
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

newline:
        push    si
        mov     si, crlf
        call    print_z
        pop     si
        ret

; DL = character
putc:
        mov     ah, 02h
        int     21h
        ret

; put_spaces: CX spaces.
put_spaces:
        jcxz    .done
.l:     mov     dl, ' '
        call    putc
        loop    .l
.done:  ret

; print_left: SI, then spaces to fill CX columns.
print_left:
        call    strlen
        call    print_z
        sub     cx, ax
        jbe     .done
        call    put_spaces
.done:  ret

; print_right: SI right-aligned in CX columns.
print_right:
        call    strlen
        sub     cx, ax
        jbe     .print
        call    put_spaces
.print: jmp     print_z

; fmt_u32: EAX in decimal, with thousands separators if BL is set.
; Out: SI = the ASCIIZ digits.
fmt_u32:
        mov     [num_commas], bl
        mov     di, numbuf + NUMBUF_SIZE - 1
        mov     byte [di], 0
        mov     ecx, 10
        xor     bl, bl                  ; digits in the current group of three
.d:     xor     edx, edx
        div     ecx
        cmp     byte [num_commas], 0
        je      .put
        cmp     bl, 3
        jne     .put
        dec     di
        mov     byte [di], ','
        xor     bl, bl
.put:   add     dl, '0'
        dec     di
        mov     [di], dl
        inc     bl
        test    eax, eax
        jnz     .d
        mov     si, di
        ret

; AX = number, printed in decimal
put_dec:
        movzx   eax, ax
        xor     bl, bl
        call    fmt_u32
        jmp     print_z

; AL = 0..99, as two digits; put2sp with a space for a leading zero
put2:   aam                             ; AH = tens, AL = ones
        push    ax
        mov     dl, ah
        add     dl, '0'
        jmp     put2_ones
put2sp: aam
        push    ax
        mov     dl, ah
        add     dl, '0'
        test    ah, ah
        jnz     put2_ones
        mov     dl, ' '
put2_ones:
        call    putc
        pop     ax
        mov     dl, al
        add     dl, '0'
        jmp     putc

; AL = byte, printed as two hex digits; put_hex16 for AX
put_hex16:
        push    ax
        mov     al, ah
        call    put_hex8
        pop     ax
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

; The same output for the critical error handler, which may not use AH=40h.
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

; print_dos_error: a message for the DOS error code in AX, to standard error.
print_dos_error:
        mov     byte [out_handle], 2
        call    .say_it
        mov     byte [out_handle], 1
        ret
.say_it:
        mov     si, msg_file_not_found
        cmp     ax, 2
        je      .say
        mov     si, msg_path_not_found
        cmp     ax, 3
        je      .say
        mov     si, msg_access_denied
        cmp     ax, 5
        je      .say
        mov     si, msg_bad_drive
        cmp     ax, 15
        je      .say
        push    ax
        mov     si, msg_dos_error
        call    print_z
        pop     ax
        call    put_dec
        jmp     newline
.say:   jmp     print_z

; ------------------------------------------------------------
; Dates and times
; ------------------------------------------------------------

; print_date: today, as "Tue 10-14-2026".
print_date:
        mov     ah, 2Ah                 ; AL = weekday, CX = year, DH = month, DL = day
        int     21h
        mov     [dt_year], cx
        mov     [dt_month], dh
        mov     [dt_day], dl
        movzx   si, al
        shl     si, 2
        add     si, day_names
        call    print_z
        mov     dl, ' '
        call    putc
        mov     al, [dt_month]
        call    put2
        mov     dl, '-'
        call    putc
        mov     al, [dt_day]
        call    put2
        mov     dl, '-'
        call    putc
        mov     ax, [dt_year]
        jmp     put_dec

; print_time: now, as "13:05:09.42", or with BL set as " 1:05:09.42p".
print_time:
        mov     [dt_12h], bl
        mov     ah, 2Ch                 ; CH = hours, CL = minutes, DH = seconds, DL = 1/100
        int     21h
        mov     [dt_month], cl
        mov     [dt_day], dh
        mov     [dt_hund], dl
        mov     al, ch
        mov     byte [dt_ampm], 'a'
        cmp     byte [dt_12h], 0
        je      .hour
        cmp     al, 12
        jb      .am
        mov     byte [dt_ampm], 'p'
        sub     al, 12
.am:    test    al, al
        jnz     .hour
        mov     al, 12
.hour:  call    put2sp
        mov     dl, ':'
        call    putc
        mov     al, [dt_month]
        call    put2
        mov     dl, ':'
        call    putc
        mov     al, [dt_day]
        call    put2
        mov     dl, '.'
        call    putc
        mov     al, [dt_hund]
        call    put2
        cmp     byte [dt_12h], 0
        je      .done
        mov     dl, [dt_ampm]
        call    putc
.done:  ret

; print_file_date: a directory entry's date (AX) as MM-DD-YY.
print_file_date:
        mov     [dt_year], ax
        shr     ax, 5
        and     al, 0Fh
        call    put2
        mov     dl, '-'
        call    putc
        mov     al, [dt_year]
        and     al, 1Fh
        call    put2
        mov     dl, '-'
        call    putc
        mov     ax, [dt_year]
        shr     ax, 9
        add     ax, 1980
        mov     bl, 100
        div     bl
        mov     al, ah
        jmp     put2

; print_file_time: a directory entry's time (AX) as " 6:22a".
print_file_time:
        mov     [dt_year], ax
        shr     ax, 11
        mov     byte [dt_ampm], 'a'
        cmp     al, 12
        jb      .am
        mov     byte [dt_ampm], 'p'
        sub     al, 12
.am:    test    al, al
        jnz     .hour
        mov     al, 12
.hour:  call    put2sp
        mov     dl, ':'
        call    putc
        mov     ax, [dt_year]
        shr     ax, 5
        and     al, 3Fh
        call    put2
        mov     dl, [dt_ampm]
        jmp     putc

; ------------------------------------------------------------
; File names
; ------------------------------------------------------------

; has_wild: CF set if the ASCIIZ name at SI has a * or a ?.
has_wild:
        push    si
.l:     lodsb
        test    al, al
        jz      .no
        cmp     al, '*'
        je      .yes
        cmp     al, '?'
        jne     .l
.yes:   pop     si
        stc
        ret
.no:    pop     si
        clc
        ret

; is_dir: CF clear if the path at DX is a directory.
is_dir:
        mov     ax, 4300h
        int     21h
        jc      .no
        test    cl, 10h
        jz      .no
        clc
        ret
.no:    stc
        ret

; last_component: BX = where the last part of the path at SI starts
; (after its last '\' or ':'). SI is used up.
last_component:
        mov     bx, si
.l:     lodsb
        test    al, al
        jz      .done
        cmp     al, '\'
        je      .s
        cmp     al, ':'
        jne     .l
.s:     mov     bx, si
        jmp     .l
.done:  ret

; dir_prefix: copy the directory part of the path at SI (up to and with
; its last '\' or ':') to DI. DI ends on the 0, where a name can go.
dir_prefix:
        push    si
        call    last_component
        pop     si
.c:     cmp     si, bx
        jae     .done
        movsb
        jmp     .c
.done:  mov     byte [di], 0
        ret

; make_pattern: what was typed (SI, maybe empty) as a search pattern in DI.
; A directory becomes dir\*.*, nothing at all *.*; with BL set a name
; without a dot also gets .*, as DIR takes it.
make_pattern:
        mov     [mp_mode], bl
        mov     [mp_dest], di
        call    append_z
        cmp     di, [mp_dest]
        je      .all
        mov     al, [di - 1]
        cmp     al, '\'
        je      .all
        cmp     al, ':'
        je      .all
        mov     si, [mp_dest]
        call    has_wild
        jc      .done
        push    di
        mov     si, [mp_dest]
        call    last_component
        pop     di
        cmp     byte [bx], '.'          ; . and .. are directories
        jne     .ask
        cmp     byte [bx + 1], 0
        je      .dir
        cmp     word [bx + 1], '.'      ; '.' and then the 0
        je      .dir
.ask:   push    bx
        mov     dx, [mp_dest]
        call    is_dir
        pop     bx
        jnc     .dir
        cmp     byte [mp_mode], 0
        je      .done
.dot:   mov     al, [bx]                ; DIR NAME lists NAME.*
        test    al, al
        jz      .no_dot
        cmp     al, '.'
        je      .done
        inc     bx
        jmp     .dot
.no_dot:
        mov     si, pat_dot_star
        jmp     append_z
.dir:   mov     al, '\'
        stosb
.all:   mov     si, pat_star_star
        jmp     append_z
.done:  ret

; truename: the full name of the path at SI, into DI (128 bytes).
truename:
        mov     ah, 60h
        int     21h
        ret

; apply_template: the name at SI (no path) renamed by the template at BX
; (no path, may hold wildcards), written to DI, as REN and COPY do it:
; DOS's own parser expands both into 8+3 FCB names, and each '?' in the
; template takes the character from the original.
apply_template:
        push    di
        push    si
        mov     si, bx
        mov     di, fcb_t
        mov     ax, 2900h
        int     21h
        pop     si
        mov     di, fcb_s
        mov     ax, 2900h
        int     21h
        pop     di
        xor     bx, bx
.merge: mov     al, [fcb_t + 1 + bx]
        cmp     al, '?'
        jne     .keep
        mov     al, [fcb_s + 1 + bx]
.keep:  mov     [fcb_r + bx], al
        inc     bx
        cmp     bx, 11
        jb      .merge
        xor     bx, bx                  ; the name, up to its padding
.name:  mov     al, [fcb_r + bx]
        cmp     al, ' '
        je      .ext
        stosb
        inc     bx
        cmp     bx, 8
        jb      .name
.ext:   cmp     byte [fcb_r + 8], ' '
        je      .end
        mov     al, '.'
        stosb
        mov     bx, 8
.e:     mov     al, [fcb_r + bx]
        cmp     al, ' '
        je      .end
        stosb
        inc     bx
        cmp     bx, 11
        jb      .e
.end:   mov     byte [di], 0
        ret

        section .data
seps            db 0, ' ', 9, 10, 13, ',', ';', '='
seps_end:
day_names       db 'Sun', 0, 'Mon', 0, 'Tue', 0, 'Wed', 0, 'Thu', 0, 'Fri', 0, 'Sat', 0
pat_star_star   db '*.*', 0
pat_dot_star    db '.*', 0
msg_file_not_found db 'File not found', 13, 10, 0
msg_path_not_found db 'Path not found', 13, 10, 0
msg_access_denied  db 'Access denied', 13, 10, 0
msg_dos_error   db 'DOS error ', 0

        section .bss
MAX_ARGS        equ 8
NUMBUF_SIZE     equ 16
argc            resw 1
argv            resw MAX_ARGS
switches        resd 1
argbuf          resb LINE_MAX + MAX_ARGS + 8
numbuf          resb NUMBUF_SIZE
num_commas      resb 1
out_handle      resb 1          ; 1, or 2 while an error is printed
mp_mode         resb 1
mp_dest         resw 1
dt_year         resw 1
dt_month        resb 1
dt_day          resb 1
dt_hund         resb 1
dt_12h          resb 1
dt_ampm         resb 1
fcb_t           resb 37
fcb_s           resb 37
fcb_r           resb 11
