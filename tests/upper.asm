; UPPER.COM - a test filter: standard input to standard output in upper
; case, up to the end of the input or a ^Z. For testing pipes.
;
; Build: nasm -f bin tests/upper.asm -o build/upper.com
        cpu     386
        bits    16
        org     100h

start:  mov     dx, buf
        mov     cx, 256
        xor     bx, bx
        mov     ah, 3Fh
        int     21h
        jc      .done
        test    ax, ax
        jz      .done
        mov     cx, ax
        mov     si, buf
        xor     dx, dx                  ; DL set once a ^Z is seen
.c:     mov     al, [si]
        cmp     al, 1Ah
        jne     .letter
        mov     cx, si                  ; write what comes before it, then stop
        sub     cx, buf
        inc     dl
        jmp     .write
.letter:
        cmp     al, 'a'
        jb      .next
        cmp     al, 'z'
        ja      .next
        sub     byte [si], 20h
.next:  inc     si
        loop    .c
        mov     cx, si
        sub     cx, buf
.write: push    dx
        mov     dx, buf
        mov     bx, 1
        mov     ah, 40h
        int     21h
        pop     dx
        test    dl, dl
        jz      start
.done:  mov     ax, 4C00h
        int     21h

buf:
