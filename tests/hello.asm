; HELLO.COM - a test program for the shell.
;
; Prints its command tail, how much memory DOS gave it and the name
; in its first FCB, then exits with the tail's length, trailing
; spaces left out, as its errorlevel. Run as HELLO WAIT it then waits for q (or Ctrl-C).
;
; Build: nasm -f bin tests/hello.asm -o build/hello.com
        cpu     386
        bits    16
        org     100h

start:
        mov     dx, msg_tail
        call    puts
        movzx   cx, byte [80h]
        mov     dx, 81h
        mov     bx, 1
        mov     ah, 40h
        int     21h
        mov     dx, msg_mem
        call    puts
        mov     ax, [2]                 ; the first segment beyond our memory
        mov     bx, cs
        sub     ax, bx
        shr     ax, 6                   ; paragraphs to kilobytes
        call    put_dec
        mov     dx, msg_fcb
        call    puts
        mov     cx, 8
        mov     dx, 5Dh
        mov     bx, 1
        mov     ah, 40h
        int     21h
        mov     dx, msg_end
        call    puts

        cmp     dword [5Dh], 'WAIT'
        jne     .exit
        mov     dx, msg_wait
        call    puts
.key:   mov     ah, 01h                 ; reads with Ctrl-C checking
        int     21h
        cmp     al, 'q'
        jne     .key
.exit:  movzx   bx, byte [80h]
.trim:  test    bx, bx
        jz      .code
        cmp     byte [80h + bx], ' '
        jne     .code
        dec     bx
        jmp     .trim
.code:  mov     al, bl
        mov     ah, 4Ch
        int     21h

puts:   mov     ah, 09h
        int     21h
        ret

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
        mov     ah, 02h
        int     21h
        loop    .out
        ret

msg_tail db 'hello: tail=[$'
msg_mem  db '] mem=$'
msg_fcb  db 'K fcb1=[$'
msg_end  db ']', 13, 10, '$'
msg_wait db 'waiting for q or Ctrl-C', 13, 10, '$'
