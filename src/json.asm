; ============================================================
; json.asm - just enough JSON to read the Messages API's answer:
; skip a value, find an object's member, an array's element,
; compare a string, and decode one. The JSON is at ES:SI (the
; answer's segment); j_end bounds it. Decoded text goes to FS:DI,
; which lets it land in our own segment or in a big one.
; Everything sets CF when the JSON is not what it should be.
; ============================================================
        section .text

; j_ws: SI past white space.
j_ws:   cmp     si, [j_end]
        jae     .done
        mov     al, [es:si]
        cmp     al, ' '
        je      .skip
        cmp     al, 9
        je      .skip
        cmp     al, 13
        je      .skip
        cmp     al, 10
        jne     .done
.skip:  inc     si
        jmp     j_ws
.done:  ret

; j_skip_string: SI on a '"', past the string.
j_skip_string:
        inc     si
.c:     cmp     si, [j_end]
        jae     .bad
        mov     al, [es:si]
        inc     si
        cmp     al, '\'
        jne     .quote
        inc     si
        jmp     .c
.quote: cmp     al, '"'
        jne     .c
        clc
        ret
.bad:   stc
        ret

; j_skip: SI past one value of any kind.
j_skip: call    j_ws
        cmp     si, [j_end]
        jae     .bad
        mov     al, [es:si]
        cmp     al, '"'
        je      j_skip_string
        cmp     al, '{'
        je      .nest
        cmp     al, '['
        je      .nest
.lit:   cmp     si, [j_end]             ; a number, true, false or null
        jae     .ok
        mov     al, [es:si]
        cmp     al, ','
        je      .ok
        cmp     al, '}'
        je      .ok
        cmp     al, ']'
        je      .ok
        cmp     al, ' '
        jbe     .ok
        inc     si
        jmp     .lit
.nest:  xor     cx, cx                  ; brackets deep
.n:     cmp     si, [j_end]
        jae     .bad
        mov     al, [es:si]
        cmp     al, '"'
        jne     .open
        push    cx
        call    j_skip_string
        pop     cx
        jc      .bad
        jmp     .n
.open:  inc     si
        cmp     al, '{'
        je      .deeper
        cmp     al, '['
        je      .deeper
        cmp     al, '}'
        je      .shallower
        cmp     al, ']'
        jne     .n
.shallower:
        dec     cx
        jnz     .n
.ok:    clc
        ret
.deeper:
        inc     cx
        jmp     .n
.bad:   stc
        ret

; j_member: SI on an object; the value of its member named by the
; ASCIIZ at DS:DI. SI on that value, or CF if there is none.
j_member:
        call    j_ws
        cmp     byte [es:si], '{'
        jne     .bad
        inc     si
.pair:  call    j_ws
        cmp     si, [j_end]
        jae     .bad
        cmp     byte [es:si], '"'
        jne     .bad
        push    si
        inc     si
        mov     bx, di
.k:     mov     al, [bx]
        test    al, al
        jz      .key_end
        cmp     al, [es:si]
        jne     .other
        inc     si
        inc     bx
        jmp     .k
.key_end:
        cmp     byte [es:si], '"'
        jne     .other
        add     sp, 2
        inc     si
        call    j_ws
        cmp     byte [es:si], ':'
        jne     .bad
        inc     si
        call    j_ws
        clc
        ret
.other: pop     si
        call    j_skip_string
        jc      .bad
        call    j_ws
        cmp     byte [es:si], ':'
        jne     .bad
        inc     si
        push    di
        call    j_skip
        pop     di
        jc      .bad
        call    j_ws
        cmp     byte [es:si], ','
        jne     .bad                    ; the end of the object: no such member
        inc     si
        jmp     .pair
.bad:   stc
        ret

; j_element: SI on an array; its element number CX. CF if it has fewer.
j_element:
        call    j_ws
        cmp     byte [es:si], '['
        jne     .bad
        inc     si
.e:     call    j_ws
        cmp     si, [j_end]
        jae     .bad
        cmp     byte [es:si], ']'
        je      .bad
        jcxz    .found
        push    cx
        call    j_skip
        pop     cx
        jc      .bad
        call    j_ws
        cmp     byte [es:si], ','
        jne     .bad
        inc     si
        dec     cx
        jmp     .e
.found: clc
        ret
.bad:   stc
        ret

; j_is: ZF set if the value at SI is the string at DS:DI exactly.
j_is:   call    j_ws
        cmp     byte [es:si], '"'
        jne     .done
        push    si
        inc     si
.c:     mov     al, [di]
        test    al, al
        jz      .end
        cmp     al, [es:si]
        jne     .no
        inc     si
        inc     di
        jmp     .c
.end:   cmp     byte [es:si], '"'
.no:    pop     si
.done:  ret

; j_string: the string at SI decoded into FS:DI (at most CX bytes, then
; a 0). \n is a line feed; \uXXXX is the character if it is ASCII, a
; look-alike for the usual typographic ones, else '?'. CF if no string.
j_string:
        call    j_ws
        cmp     byte [es:si], '"'
        jne     .bad
        inc     si
        dec     cx                      ; room for the 0
.c:     cmp     si, [j_end]
        jae     .bad
        mov     al, [es:si]
        inc     si
        cmp     al, '"'
        je      .end
        cmp     al, '\'
        jne     .put
        mov     al, [es:si]
        inc     si
        cmp     al, 'n'
        jne     .t
        mov     al, 10
        jmp     .put
.t:     cmp     al, 't'
        jne     .r
        mov     al, ' '
        jmp     .put
.r:     cmp     al, 'r'
        je      .c
        cmp     al, 'b'
        je      .c
        cmp     al, 'f'
        je      .c
        cmp     al, 'u'
        jne     .put                    ; \" \\ \/ are the character itself
        call    .hex4
        cmp     ax, 128
        jb      .ascii
        push    di
        mov     di, j_lookalike
.l:     mov     bx, [di]
        test    bx, bx
        jz      .unknown
        cmp     bx, ax
        je      .alike
        add     di, 4
        jmp     .l
.alike: mov     ax, [di + 2]
        pop     di
        jmp     .put_pair
.unknown:
        pop     di
        mov     al, '?'
        jmp     .put
.ascii: test    al, al
        jz      .c
.put:   jcxz    .c
        mov     [fs:di], al
        inc     di
        dec     cx
        jmp     .c
.put_pair:                              ; one or two characters (an ellipsis is "..")
        push    ax
        call    .put1
        pop     ax
        mov     al, ah
        test    al, al
        jz      .c
        jmp     .put
.put1:  jcxz    .p1
        mov     [fs:di], al
        inc     di
        dec     cx
.p1:    ret
.end:   mov     byte [fs:di], 0
        clc
        ret
.bad:   mov     byte [fs:di], 0
        stc
        ret
.hex4:  xor     bx, bx                  ; four hex digits at SI into AX
        mov     dx, 4
.h:     mov     al, [es:si]
        inc     si
        or      al, 20h
        sub     al, '0'
        cmp     al, 9
        jbe     .digit
        sub     al, 'a' - '0' - 10
.digit: shl     bx, 4
        and     al, 0Fh
        or      bl, al
        dec     dx
        jnz     .h
        mov     ax, bx
        ret

; j_escape: the ASCIIZ at DS:SI as JSON string text (no quotes) at ES:DI.
; Characters that are not plain ASCII become '?'.
j_escape:
        lodsb
        test    al, al
        jz      .done
        cmp     al, '"'
        je      .esc
        cmp     al, '\'
        je      .esc
        cmp     al, 9
        je      .space
        cmp     al, ' '
        jb      j_escape
        cmp     al, 127
        jb      .put
        mov     al, '?'
        jmp     .put
.space: mov     al, ' '
        jmp     .put
.esc:   mov     byte [es:di], '\'
        inc     di
.put:   stosb
        jmp     j_escape
.done:  ret

        section .data
; Unicode characters Claude might use anyway, and what to show instead
j_lookalike     dw 2018h, "'", 2019h, "'", 201Ch, '"', 201Dh, '"'
                dw 2013h, '-', 2014h, '--', 2026h, '..', 00A0h, ' ', 2022h, '*'
                dw 00D7h, 'x', 2192h, '->', 0

        section .bss
j_end           resw 1
