; ============================================================
; CLAUDE.COM - a shell for DOS that talks to Claude.
;
; Phase 0: a stub that proves the build, the disk images and
; SHELL=. It says which DOS it booted on and echoes lines back;
; COMMAND.COM is never loaded.
;
; 386 real mode: 32-bit registers are allowed, but DOS and BIOS
; calls only promise to keep the low 16 bits of each register.
;
; Build: nasm -f bin src/claude.asm -o build/claude.com
; ============================================================
        cpu     386
        bits    16
        org     100h

start:
        ; Ctrl-C ends the running program through INT 23h, and the system
        ; shell must never end: answer it with a plain IRET for now.
        mov     dx, ignore_break
        mov     ax, 2523h
        int     21h

        mov     dx, banner
        call    puts

        ; INT 21h AH=30h: AL = major, AH = minor, BH = OEM number
        mov     ah, 30h
        int     21h
        push    bx
        push    ax
        mov     dx, dos_is
        call    puts
        pop     ax
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
        mov     dx, oem_is
        call    puts
        pop     bx
        mov     al, bh
        call    put_hex8
        mov     dx, crlf
        call    puts

main_loop:
        mov     dx, prompt
        call    puts
        mov     dx, inbuf
        mov     ah, 0Ah                 ; buffered line input
        int     21h
        mov     dx, crlf
        call    puts
        movzx   cx, byte [inbuf + 1]    ; characters typed, without the CR
        jcxz    main_loop
        mov     dx, said
        call    puts
        mov     bx, 1                   ; standard output
        mov     dx, inbuf + 2
        mov     ah, 40h
        int     21h
        mov     dx, crlf
        call    puts
        jmp     main_loop

ignore_break:
        iret

; DX = '$'-terminated string
puts:
        mov     ah, 09h
        int     21h
        ret

; DL = character
putc:
        mov     ah, 02h
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

banner  db      'Claude shell for DOS - phase 0 stub (386 real mode)', 13, 10
        db      'It only echoes for now. COMMAND.COM is not loaded.', 13, 10, '$'
dos_is  db      'Booted on DOS $'
oem_is  db      ', OEM number $'
prompt  db      13, 10, 'C:\> $'
said    db      'You typed: $'
crlf    db      13, 10, '$'

inbuf   db      120, 0
        times 121 db 0
