; ============================================================
; env.asm - the shell's own environment: a block made at
; start-up with room to grow (/E:n), read and changed by SET,
; PATH and PROMPT, and copied by DOS to every program we run.
; It is a list of NAME=value strings, each ending in a 0, and
; one more 0 after the last.
; ============================================================
ENV_DEFAULT     equ 1024

        section .text

; init_env: a block of our own, holding what we were given.
init_env:
        mov     bx, [env_want]
        test    bx, bx
        jnz     .clamp
        mov     bx, ENV_DEFAULT
.clamp: cmp     bx, 160
        jae     .not_small
        mov     bx, 160
.not_small:
        cmp     bx, 32768
        jbe     .not_big
        mov     bx, 32768
.not_big:
        add     bx, 15
        shr     bx, 4
        mov     [env_paras], bx
        mov     ah, 48h
        int     21h
        jc      .keep
        mov     [env_new], ax
        mov     ax, [env_paras]
        shl     ax, 4
        mov     [env_size], ax

        mov     es, [env_new]
        xor     di, di
        mov     ax, [PSP_ENV]
        test    ax, ax
        jz      .copied
        push    ds
        mov     ds, ax
        xor     si, si
.str:   cmp     byte [si], 0
        je      .end_of_old
        mov     bx, si                  ; BX past the end of this string
.len:   inc     bx
        cmp     byte [bx - 1], 0
        jne     .len
        mov     cx, bx
        sub     cx, si
        mov     ax, di
        add     ax, cx
        cmp     ax, [cs:env_size]
        jae     .drop                   ; keep room for the final 0
        rep     movsb
        jmp     .str
.drop:  mov     si, bx
        jmp     .str
.end_of_old:
        ; DOS 3 and later put a count and the program's own name after it
        cmp     word [si + 1], 1
        jne     .no_name
        add     si, 3
        push    es
        push    di
        push    cs
        pop     es
        mov     di, own_path
        mov     cx, 127
.name:  lodsb
        stosb
        test    al, al
        jz      .named
        loop    .name
        mov     byte [es:di], 0
.named: pop     di
        pop     es
.no_name:
        pop     ds
.copied:
        mov     byte [es:di], 0
        ; give back the block we were given, if it is ours to give
        mov     ax, [PSP_ENV]
        test    ax, ax
        jz      .switch
        dec     ax
        mov     es, ax
        inc     ax
        mov     bx, cs
        cmp     [es:1], bx
        jne     .switch
        mov     es, ax
        mov     ah, 49h
        int     21h
.switch:
        mov     ax, [env_new]
        mov     [PSP_ENV], ax
        push    cs
        pop     es
        ret
.keep:  ; no memory to spare: keep the one we were given, as big as its block
        mov     word [env_size], 0
        mov     ax, [PSP_ENV]
        test    ax, ax
        jz      .kept
        dec     ax
        mov     es, ax
        mov     ax, [es:3]
        shl     ax, 4
        mov     [env_size], ax
        push    cs
        pop     es
.kept:  ret

; set_comspec: point COMSPEC at us when DOS started us (we are the
; shell programs should start) or when nobody set it.
set_comspec:
        call    guess_own_path
        cmp     byte [own_path + 1], ':'    ; a full name, as DOS gives it
        jne     .done
        cmp     byte [by_dos], 0
        jne     .set
        mov     si, name_comspec
        call    env_find
        push    cs
        pop     es
        jnc     .done
.set:   mov     si, name_comspec
        mov     bx, own_path
        call    env_set
.done:  ret

; guess_own_path: DOS does not tell a program started by SHELL= its own
; name. Make it up as COMMAND.COM would: the directory we were given
; (SHELL=C:\CLAUDE.COM C:\) or the boot drive's root, and the name DOS
; wrote in our memory block's arena header, if that file is there.
guess_own_path:
        cmp     byte [own_path], 0
        jne     .done
        mov     di, own_path
        cmp     byte [home_dir], 0
        je      .boot
        mov     si, home_dir
        call    append_z
        cmp     byte [di - 1], '\'
        je      .name
        mov     al, '\'
        stosb
        jmp     .name
.boot:  mov     ax, 3305h               ; DL = the boot drive, 1 = A:
        int     21h
        mov     al, dl
        add     al, 'A' - 1
        stosb
        mov     ax, ':' + ('\' << 8)
        stosw
.name:  push    ds
        mov     ax, cs
        dec     ax
        mov     ds, ax
        mov     si, 8                   ; up to 8 characters, ending in a 0 if fewer
        mov     cx, 8
.n:     lodsb
        test    al, al
        jz      .n_end
        stosb
        loop    .n
.n_end: pop     ds
        mov     si, dot_exts            ; '.COM', 0
        call    append_z
        mov     dx, own_path
        call    exists
        jnc     .done
        mov     byte [own_path], 0
.done:  ret

; env_find: the string for the name at SI (upper case, ASCIIZ).
; Out: ES = the environment, DI = where "NAME=..." starts; CF if absent.
env_find:
        mov     es, [PSP_ENV]
        cmp     word [env_size], 0
        je      .absent
        xor     di, di
.var:   cmp     byte [es:di], 0
        je      .absent
        push    si
        push    di
.cmp:   lodsb
        test    al, al
        jz      .name_end
        cmp     al, [es:di]
        jne     .no
        inc     di
        jmp     .cmp
.name_end:
        cmp     byte [es:di], '='
        jne     .no
        pop     di
        pop     si
        clc
        ret
.no:    pop     di
        pop     si
        xor     al, al
        mov     cx, 0FFFFh
        repne   scasb
        jmp     .var
.absent:
        stc
        ret

; env_get: the value of the name at SI copied to DI (at most CX bytes).
; CF if there is no such variable.
env_get:
        push    di
        push    cx
        call    env_find
        pop     cx
        pop     bx
        jc      .absent
        push    cx
        mov     al, '='
        mov     cx, 0FFFFh
        repne   scasb
        pop     cx
.c:     mov     al, [es:di]
        mov     [bx], al
        test    al, al
        jz      .done
        inc     di
        inc     bx
        loop    .c
        mov     byte [bx], 0
.done:  push    cs
        pop     es
        clc
        ret
.absent:
        push    cs
        pop     es
        stc
        ret

; env_end_at: DI from a string's start to the environment's final 0.
env_end_at:
        cmp     byte [es:di], 0
        je      .done
        xor     al, al
        mov     cx, 0FFFFh
        repne   scasb
        jmp     env_end_at
.done:  ret

; env_set: NAME (SI, upper case) = value (BX). An empty value removes it.
; CF, after saying so, if there is no room.
env_set:
        cmp     word [env_size], 0
        je      .full
        push    si
        call    env_find
        jc      .add
        mov     dx, di                  ; remove it: what follows moves down
        xor     al, al
        mov     cx, 0FFFFh
        repne   scasb
        mov     si, di
        call    env_end_at
        mov     cx, di
        sub     cx, si
        inc     cx
        mov     di, dx
        push    ds
        push    es
        pop     ds
        rep     movsb
        pop     ds
.add:   pop     si
        cmp     byte [bx], 0
        je      .done
        push    si
        call    strlen
        mov     cx, ax
        mov     si, bx
        call    strlen
        add     cx, ax
        add     cx, 3                   ; '=', its 0 and the final 0
        pop     si
        mov     es, [PSP_ENV]
        xor     di, di
        push    cx
        call    env_end_at              ; (it uses CX)
        pop     cx
        mov     ax, di
        add     ax, cx
        cmp     ax, [env_size]
        ja      .full
        call    append_z
        mov     al, '='
        stosb
        mov     si, bx
        call    append_z
        inc     di
        mov     byte [es:di], 0
.done:  push    cs
        pop     es
        clc
        ret
.full:  push    cs
        pop     es
        mov     si, msg_env_full
        call    print_err
        stc
        ret

; env_list: every variable, one to a line, as SET shows them.
env_list:
        mov     ax, [PSP_ENV]
        cmp     word [env_size], 0
        je      .none
        push    ds
        mov     ds, ax
        xor     si, si
.s:     cmp     byte [si], 0
        je      .done
        call    print_z
        mov     dl, 13
        call    putc
        mov     dl, 10
        call    putc
        call    strlen
        add     si, ax
        inc     si
        jmp     .s
.done:  pop     ds
.none:  ret

        section .data
name_comspec    db 'COMSPEC', 0
name_path       db 'PATH', 0
name_prompt     db 'PROMPT', 0
msg_env_full    db 'Out of environment space', 13, 10, 0

        section .bss
env_want        resw 1          ; /E:n
env_paras       resw 1
env_new         resw 1
env_size        resw 1          ; bytes; 0 when there is no environment
own_path        resb 128        ; our own name, as DOS gave it
