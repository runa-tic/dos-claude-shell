; HELLOX.EXE - the smallest .EXE test program: an MZ header by hand.
; Prints its command tail and exits with errorlevel 7.
;
; Build: nasm -f bin tests/hellox.asm -o build/hellox.exe
        cpu     386
        bits    16

STACK   equ     256

        section header start=0
        db      'MZ'
        dw      file_size % 512         ; bytes in the last 512-byte page
        dw      (file_size + 511) / 512 ; pages
        dw      0                       ; relocations
        dw      2                       ; header size in paragraphs
        dw      (STACK + 15) / 16       ; extra memory needed, for the stack
        dw      0FFFFh                  ; extra memory wanted
        dw      0                       ; SS, relative to the load segment
        dw      code_size + STACK       ; SP
        dw      0                       ; checksum
        dw      0                       ; IP
        dw      0                       ; CS, relative
        dw      1Ch                     ; relocation table offset
        dw      0                       ; overlay
        times   32 - ($ - $$) db 0

        section code follows=header vstart=0
start:
        ; DS = ES = our PSP on entry
        mov     cx, 0
        mov     cl, [80h]
        push    cx
        push    cs
        pop     ds
        mov     dx, msg
        mov     ah, 09h
        int     21h
        pop     cx
        mov     ah, 51h                 ; the PSP again, for the tail
        int     21h
        mov     ds, bx
        mov     dx, 81h
        mov     bx, 1
        mov     ah, 40h
        int     21h
        push    cs
        pop     ds
        mov     dx, msg_end
        mov     ah, 09h
        int     21h
        mov     ax, 4C07h
        int     21h

msg     db      'hellox: an .EXE, tail=[$'
msg_end db      ']', 13, 10, '$'
code_size equ   $ - start
file_size equ   32 + code_size
