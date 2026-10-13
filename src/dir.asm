; ============================================================
; dir.asm - DIR [drive:][path][name] [/W] [/B] [/P] [/A]
;   /W wide, five names to a line   /B bare names only
;   /P pause after each screenful    /A hidden and system files too
; ============================================================
SW_A            equ 'A' - 'A'
SW_B            equ 'B' - 'A'
SW_P            equ 'P' - 'A'
SW_W            equ 'W' - 'A'

        section .text

cmd_dir:
        call    parse_args
        mov     si, empty_str
        cmp     word [argc], 0
        je      .pattern
        mov     si, [argv]
.pattern:
        mov     di, patbuf
        mov     bl, 1
        call    make_pattern
        xor     eax, eax
        mov     [dir_files], ax
        mov     [dir_dirs], ax
        mov     [dir_bytes], eax
        mov     [dir_lines], ax
        mov     [dir_col], al
        mov     al, [patbuf]            ; the drive it is on
        call    upcase
        sub     al, 'A' - 1
        cmp     byte [patbuf + 1], ':'
        je      .drive
        mov     ah, 19h
        int     21h
        inc     al
.drive: mov     [dir_drive], al
        bt      dword [switches], SW_B
        jc      .list

        call    print_volume
        add     word [dir_lines], 2
        mov     si, msg_dir_of
        call    print_z
        mov     si, patbuf              ; the directory's full name: the pattern's,
        mov     di, pathbuf             ; less its last part
        call    truename
        jc      .as_typed
        mov     si, pathbuf
        call    last_component
        dec     bx
        cmp     bx, pathbuf + 2         ; a root keeps its backslash
        jne     .cut
        inc     bx
.cut:   mov     byte [bx], 0
        jmp     .show_dir
.as_typed:
        mov     si, patbuf
        mov     di, pathbuf
        call    dir_prefix
.show_dir:
        mov     si, pathbuf
        call    print_z
        call    dir_newline
        call    dir_newline

.list:  mov     dx, dta
        mov     ah, 1Ah
        int     21h
        mov     cx, 10h                 ; files and directories
        bt      dword [switches], SW_A
        jnc     .find
        mov     cx, 16h                 ; hidden and system ones as well
.find:  mov     dx, patbuf
        mov     ah, 4Eh
        int     21h
        jc      .none
.entry: test    byte [dta + 15h], 06h
        jz      .shown
        bt      dword [switches], SW_A
        jnc     .next
.shown: test    byte [dta + 15h], 10h
        jz      .file
        inc     word [dir_dirs]
        jmp     .show
.file:  inc     word [dir_files]
        mov     eax, [dta + 1Ah]
        add     [dir_bytes], eax
.show:  call    dir_entry
.next:  mov     ah, 4Fh
        int     21h
        jnc     .entry
        cmp     byte [dir_col], 0       ; a wide line still open
        je      .ended
        call    dir_newline
.ended: bt      dword [switches], SW_B
        jc      .done
        mov     ax, [dir_files]
        add     ax, [dir_dirs]
        jz      .not_found

        movzx   eax, word [dir_files]
        xor     bl, bl
        call    fmt_u32
        mov     cx, 9
        call    print_right
        mov     si, msg_files
        call    print_z
        mov     eax, [dir_bytes]
        mov     bl, 1
        call    fmt_u32
        mov     cx, 15
        call    print_right
        mov     si, msg_bytes
        call    print_z
        call    dir_newline
        movzx   eax, word [dir_dirs]
        xor     bl, bl
        call    fmt_u32
        mov     cx, 9
        call    print_right
        mov     si, msg_dirs
        call    print_z
        mov     ah, 36h                 ; AX = sectors per cluster, BX = free clusters,
        mov     dl, [dir_drive]         ; CX = bytes per sector
        int     21h
        cmp     ax, 0FFFFh
        je      .no_free
        movzx   eax, ax
        movzx   ebx, bx
        imul    eax, ebx
        movzx   ecx, cx
        imul    eax, ecx
        mov     bl, 1
        call    fmt_u32
        mov     cx, 15
        call    print_right
        mov     si, msg_bytes_free
        call    print_z
.no_free:
        jmp     dir_newline
.none:  bt      dword [switches], SW_B
        jc      .done
.not_found:
        mov     si, msg_file_not_found
        jmp     print_err
.done:  ret

; dir_entry: the entry in the DTA, as a line, a bare name or a wide column.
dir_entry:
        bt      dword [switches], SW_B
        jc      .bare
        bt      dword [switches], SW_W
        jc      .wide
        call    split_name
        mov     si, nbuf
        mov     cx, 9
        call    print_left
        mov     si, ebuf
        mov     cx, 3
        call    print_left
        test    byte [dta + 15h], 10h
        jz      .size
        mov     si, msg_dir_tag
        call    print_z
        jmp     .stamp
.size:  mov     eax, [dta + 1Ah]
        mov     bl, 1
        call    fmt_u32
        mov     cx, 14
        call    print_right
.stamp: mov     dl, ' '
        call    putc
        mov     ax, [dta + 18h]
        call    print_file_date
        mov     dl, ' '
        call    putc
        mov     dl, ' '
        call    putc
        mov     ax, [dta + 16h]
        call    print_file_time
        jmp     dir_newline
.bare:  cmp     byte [dta + 1Eh], '.'   ; no . and .. in a bare list
        je      .done
        mov     si, dta + 1Eh
        call    print_z
        jmp     dir_newline
.wide:  mov     di, wbuf                ; [DIRNAME] or NAME.EXT, 16 columns each
        test    byte [dta + 15h], 10h
        jz      .wname
        mov     al, '['
        stosb
.wname: mov     si, dta + 1Eh
        call    append_z
        test    byte [dta + 15h], 10h
        jz      .wpad
        mov     ax, ']'
        stosw
.wpad:  mov     si, wbuf
        inc     byte [dir_col]
        cmp     byte [dir_col], 5
        jae     .wlast
        mov     cx, 16
        jmp     print_left
.wlast: mov     byte [dir_col], 0
        call    print_z
        jmp     dir_newline
.done:  ret

; split_name: the DTA's NAME.EXT into nbuf and ebuf (. and .. whole).
split_name:
        mov     si, dta + 1Eh
        mov     di, nbuf
        mov     byte [ebuf], 0
        cmp     byte [si], '.'
        je      .whole
.n:     lodsb
        test    al, al
        jz      .end
        cmp     al, '.'
        je      .ext
        stosb
        jmp     .n
.ext:   mov     byte [di], 0
        mov     di, ebuf
.whole: jmp     append_z
.end:   mov     byte [di], 0
        ret

; dir_newline: a line ended; with /P, wait after every 23.
dir_newline:
        call    newline
        bt      dword [switches], SW_P
        jnc     .done
        inc     word [dir_lines]
        cmp     word [dir_lines], 23
        jb      .done
        mov     word [dir_lines], 0
        mov     si, msg_pause
        call    print_z
        mov     ah, 08h
        int     21h
        call    newline
.done:  ret

        section .data
msg_dir_of      db ' Directory of ', 0
msg_dir_tag     db '    <DIR>     ', 0
msg_files       db ' file(s)', 0
msg_bytes       db ' bytes', 0
msg_dirs        db ' dir(s)', 0
msg_bytes_free  db ' bytes free', 0

        section .bss
dir_bytes       resd 1
dir_files       resw 1
dir_dirs        resw 1
dir_lines       resw 1
dir_col         resb 1
dir_drive       resb 1
nbuf            resb 16
ebuf            resb 8
wbuf            resb 20
