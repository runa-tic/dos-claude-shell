; HANG.COM - a test program that never ends by itself, as DEBUG does when
; its piped commands run out: it takes Ctrl-C for itself and keeps making
; DOS calls. For testing the way out of a command Claude ran.
;
; Build: nasm -f bin tests/hang.asm -o build/hang.com
        cpu     386
        bits    16
        org     100h

start:  mov     dx, ignore
        mov     ax, 2523h
        int     21h
        mov     dx, msg
        mov     ah, 09h
        int     21h
.loop:  mov     ah, 0Bh                 ; input waiting? (never mind)
        int     21h
        jmp     .loop

ignore: iret                            ; Ctrl-C: carry on

msg     db 'HANG: waiting forever', 13, 10, '$'
