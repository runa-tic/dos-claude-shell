; ============================================================
; copy.asm - COPY source [destination]
;
; The source may hold wildcards or name a directory (all its
; files). The destination may be a directory (or left out: the
; current one), a name with wildcards (COPY *.TXT *.BAK), or one
; file; several sources into one file are joined. A device as the
; source is read up to a ^Z: COPY CON FILE.TXT. Copies keep the
; original's date and time. Always binary, no /A or '+' yet.
; ============================================================
CP_DIR          equ 0
CP_TEMPLATE     equ 1
CP_FILE         equ 2

        section .text

cmd_copy:
        call    parse_args
        cmp     word [argc], 0
        jne     .go
        jmp     required_missing
.go:    mov     word [copied], 0

        ; where to: a directory, a name pattern, or one file
        mov     si, empty_str
        cmp     word [argc], 2
        jb      .dst
        mov     si, [argv + 2]
.dst:   mov     di, dstbuf
        call    append_z
        mov     byte [cp_mode], CP_DIR
        cmp     di, dstbuf
        je      .dst_known
        mov     al, [di - 1]
        cmp     al, '\'
        je      .dst_known
        cmp     al, ':'
        je      .dst_known
        push    di
        mov     dx, dstbuf
        call    is_dir
        pop     di
        jc      .not_dir
        mov     ax, '\'
        stosw
        jmp     .dst_known
.not_dir:
        mov     byte [cp_mode], CP_FILE
        mov     si, dstbuf
        call    has_wild
        jnc     .dst_known
        mov     byte [cp_mode], CP_TEMPLATE
        mov     si, dstbuf
        mov     di, dstdir
        call    dir_prefix
        mov     si, dstbuf
        call    last_component
        mov     [dst_tmpl], bx
.dst_known:
        call    get_buffer

        ; a device as the source: COPY CON FILE
        mov     si, [argv]
        call    has_wild
        jc      .files
        mov     dx, si
        mov     ax, 3D00h
        int     21h
        jc      .files
        mov     bx, ax
        mov     ax, 4400h
        int     21h
        test    dl, 80h
        jnz     .device
        mov     ah, 3Eh
        int     21h

.files: mov     si, [argv]
        mov     di, patbuf
        xor     bl, bl
        call    make_pattern
        mov     si, patbuf
        mov     di, srcpath
        call    dir_prefix
        mov     [src_at], di
        mov     si, patbuf
        call    has_wild
        setc    [cp_many]
        mov     dx, dta
        mov     ah, 1Ah
        int     21h
        xor     cx, cx
        mov     dx, patbuf
        mov     ah, 4Eh
        int     21h
        jnc     .each
        mov     si, msg_file_not_found
        call    print_err
        jmp     .report

.each:  mov     di, [src_at]
        mov     si, dta + 1Eh
        call    append_z
        mov     di, dstpath
        cmp     byte [cp_mode], CP_FILE
        je      .named
        cmp     byte [cp_mode], CP_DIR
        je      .into
        mov     si, dstdir
        call    append_z
        mov     si, dta + 1Eh
        mov     bx, [dst_tmpl]
        call    apply_template
        jmp     .ready
.into:  mov     si, dstbuf
        call    append_z
        mov     si, dta + 1Eh
        call    append_z
        jmp     .ready
.named: mov     si, dstbuf
        call    append_z
.ready: cmp     byte [cp_many], 0
        je      .same
        mov     si, srcpath
        call    print_z
        call    newline
.same:  mov     si, srcpath             ; never onto itself
        mov     di, pathbuf
        call    truename
        mov     si, dstpath
        mov     di, pathbuf2
        call    truename
        mov     si, pathbuf
        mov     di, pathbuf2
        call    str_same
        jne     .copy
        mov     si, msg_onto_itself
        call    print_err
        jmp     .report
.copy:  mov     byte [cp_append], 0     ; into one file, the second source on is added
        cmp     byte [cp_mode], CP_FILE
        jne     .do
        cmp     word [copied], 0
        je      .do
        mov     byte [cp_append], 1
.do:    call    copy_file
        jc      .report
        inc     word [copied]
        mov     ah, 4Fh
        int     21h
        jnc     .each
        jmp     .report

.device:
        mov     [h_src], bx
        cmp     byte [cp_mode], CP_FILE
        je      .stream
        mov     ah, 3Eh
        int     21h
        call    invalid_parameter
        jmp     .report
.stream:
        call    copy_stream
        jc      .report
        inc     word [copied]

.report:
        call    free_buffer
        movzx   eax, word [copied]
        xor     bl, bl
        call    fmt_u32
        mov     cx, 9
        call    print_right
        mov     si, msg_copied
        jmp     print_z

; copy_file: srcpath to dstpath, or onto its end if cp_append. CF on failure.
copy_file:
        mov     dx, srcpath
        mov     ax, 3D00h
        int     21h
        jnc     .src_open
        call    print_dos_error
        stc
        ret
.src_open:
        mov     [h_src], ax
        cmp     byte [cp_append], 0
        jne     .append
        mov     dx, dstpath
        xor     cx, cx
        mov     ah, 3Ch
        int     21h
        jc      .dst_failed
        mov     [h_dst], ax
        jmp     .loop
.append:
        mov     dx, dstpath
        mov     ax, 3D01h
        int     21h
        jc      .dst_failed
        mov     [h_dst], ax
        mov     bx, ax
        mov     ax, 4202h
        xor     cx, cx
        xor     dx, dx
        int     21h
.loop:  call    read_chunk
        jc      .io_error
        test    ax, ax
        jz      .eof
        mov     cx, ax
        call    write_chunk
        jc      .io_error
        cmp     ax, cx
        jb      .full
        jmp     .loop
.eof:   cmp     byte [cp_append], 0
        jne     .close
        mov     bx, [h_src]             ; keep the original's date and time
        mov     ax, 5700h
        int     21h
        mov     bx, [h_dst]
        mov     ax, 5701h
        int     21h
.close: call    close_both
        clc
        ret
.full:  call    close_both
        mov     dx, dstpath
        mov     ah, 41h
        int     21h
        mov     si, msg_disk_full
        call    print_err
        stc
        ret
.io_error:
        push    ax
        call    close_both
        pop     ax
        call    print_dos_error
        stc
        ret
.dst_failed:
        push    ax
        mov     bx, [h_src]
        mov     ah, 3Eh
        int     21h
        pop     ax
        call    print_dos_error
        stc
        ret

; copy_stream: the open device h_src into the file dstbuf, up to a ^Z.
copy_stream:
        mov     dx, dstbuf
        xor     cx, cx
        mov     ah, 3Ch
        int     21h
        jnc     .created
        push    ax
        mov     bx, [h_src]
        mov     ah, 3Eh
        int     21h
        pop     ax
        call    print_dos_error
        stc
        ret
.created:
        mov     [h_dst], ax
.loop:  call    read_chunk
        jc      .done
        test    ax, ax
        jz      .done
        mov     cx, ax
        push    es
        push    cx
        mov     es, [buf_seg]
        mov     di, [buf_off]
        mov     al, 1Ah
        repne   scasb
        pop     cx
        pop     es
        mov     byte [cp_eof], 0
        jne     .write
        mov     cx, di                  ; a ^Z: what comes before it, then stop
        sub     cx, [buf_off]
        dec     cx
        mov     byte [cp_eof], 1
.write: call    write_chunk
        cmp     byte [cp_eof], 0
        je      .loop
.done:  call    close_both
        clc
        ret

; read_chunk: from h_src into the buffer. AX = bytes read, CF on error.
read_chunk:
        mov     bx, [h_src]
        mov     cx, [buf_bytes]
        mov     dx, [buf_off]
        push    ds
        mov     ds, [buf_seg]
        mov     ah, 3Fh
        int     21h
        pop     ds
        ret

; write_chunk: CX bytes from the buffer to h_dst. AX = bytes written.
write_chunk:
        mov     bx, [h_dst]
        mov     dx, [buf_off]
        push    ds
        mov     ds, [buf_seg]
        mov     ah, 40h
        int     21h
        pop     ds
        ret

close_both:
        mov     bx, [h_src]
        mov     ah, 3Eh
        int     21h
        mov     bx, [h_dst]
        mov     ah, 3Eh
        int     21h
        ret

; get_buffer: 32 KB from DOS for copying, less if that is all there is,
; or our own 512 bytes if DOS has nothing.
get_buffer:
        mov     byte [buf_owned], 0
        mov     bx, 0800h
        mov     ah, 48h
        int     21h
        jnc     .got
        cmp     bx, 32                  ; the most there is, if it is worth having
        jb      .ours
        mov     ah, 48h
        int     21h
        jc      .ours
.got:   mov     [buf_seg], ax
        mov     word [buf_off], 0
        shl     bx, 4
        mov     [buf_bytes], bx
        mov     byte [buf_owned], 1
        ret
.ours:  mov     [buf_seg], cs
        mov     word [buf_off], iobuf
        mov     word [buf_bytes], IOBUF_SIZE
        ret

free_buffer:
        cmp     byte [buf_owned], 0
        je      .done
        mov     es, [buf_seg]
        mov     ah, 49h
        int     21h
        push    cs
        pop     es
        mov     byte [buf_owned], 0
.done:  ret

; str_same: ZF set if the ASCIIZ strings at SI and DI are equal.
str_same:
        mov     al, [si]
        cmp     al, [di]
        jne     .done
        test    al, al
        jz      .done
        inc     si
        inc     di
        jmp     str_same
.done:  ret

        section .data
msg_copied      db ' file(s) copied', 13, 10, 0
msg_onto_itself db 'File cannot be copied onto itself', 13, 10, 0
msg_disk_full   db 'Insufficient disk space', 13, 10, 0

        section .bss
dstbuf          resb 2 * NAME_MAX + 16
dstdir          resb 2 * NAME_MAX + 16
dstpath         resb 2 * NAME_MAX + 16
srcpath         resb 2 * NAME_MAX + 16
pathbuf2        resb 2 * NAME_MAX + 16
dst_tmpl        resw 1
src_at          resw 1
copied          resw 1
buf_seg         resw 1
buf_off         resw 1
buf_bytes       resw 1
cp_mode         resb 1
cp_many         resb 1
cp_append       resb 1
cp_eof          resb 1
buf_owned       resb 1
