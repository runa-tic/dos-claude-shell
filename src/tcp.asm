; ============================================================
; tcp.asm - one TCP connection, as a client; HTTP over it; the
; FETCH command.
;
; Made for a request and its answer on a short, lossless link (a
; virtual machine's user network): we send stop-and-wait, one
; segment at a time, until it is acknowledged; we take what comes
; in order only, acknowledging every segment, and advertise a
; window small enough for the packet ring to hold a whole burst.
; Lost segments are sent again on a timeout that doubles. The
; answer goes into a buffer from DOS (http_seg) of up to 60 KB.
; Sequence numbers are kept in host order.
; ============================================================
TCP_MSS         equ 1460
TCP_WINDOW      equ 4 * TCP_MSS
T_CLOSED        equ 0
T_SYN_SENT      equ 1
T_OPEN          equ 2
TF_FIN          equ 01h
TF_SYN          equ 02h
TF_RST          equ 04h
TF_PSH          equ 08h
TF_ACK          equ 10h
HTTP_PARAS      equ 0F00h       ; 60 KB for the answer

        section .text

; tcp_connect: to IP EAX, port BX (host order). The network is open.
; CF after saying why not.
tcp_connect:
        mov     [t_ip], eax
        xchg    bl, bh
        mov     [t_rport], bx
        call    arp_resolve
        jnc     .route
        mov     si, msg_no_route
        jmp     .fail
.route: mov     si, arp_mac
        mov     di, t_mac
        movsd
        movsw
        call    ticks                   ; our port and first sequence number: the clock's
        mov     bx, ax
        and     bx, 3FFFh
        add     bx, 49152
        xchg    bl, bh
        mov     [t_lport], bx
        movzx   eax, ax
        imul    eax, eax, 9E3779B1h
        mov     [t_iss], eax
        mov     [snd_una], eax
        inc     eax
        mov     [snd_nxt], eax
        mov     word [t_peer_mss], 536
        mov     byte [t_fin], 0
        mov     byte [t_rst], 0
        mov     byte [t_state], T_SYN_SENT
        mov     byte [t_tries], 5
        mov     word [t_rto], 18
.syn:   mov     eax, [t_iss]
        mov     bl, TF_SYN
        xor     cx, cx
        call    tcp_segment
        call    ticks
        mov     [t_start], ax
.wait:  cmp     byte [t_state], T_SYN_SENT
        jne     .answered
        call    net_wait
        sub     ax, [t_start]
        cmp     ax, [t_rto]
        jb      .wait
        shl     word [t_rto], 1
        dec     byte [t_tries]
        jnz     .syn
        mov     si, msg_tcp_timeout
        jmp     .fail
.answered:
        cmp     byte [t_state], T_OPEN
        je      .ok
        mov     si, msg_tcp_refused
.fail:  mov     byte [t_state], T_CLOSED
        call    print_err
        stc
        ret
.ok:    clc
        ret

; tcp_segment: a segment with flags BL and sequence number EAX, carrying
; CX bytes from tx_seg:tx_off (and an ACK of rcv_nxt if BL has TF_ACK).
tcp_segment:
        mov     [seg_len], cx
        call    hton32
        mov     [txf + 38], eax
        mov     ax, [t_lport]
        mov     [txf + 34], ax
        mov     ax, [t_rport]
        mov     [txf + 36], ax
        xor     eax, eax
        test    bl, TF_ACK
        jz      .no_ack
        mov     eax, [rcv_nxt]
        call    hton32
.no_ack:
        mov     [txf + 42], eax
        mov     [txf + 47], bl
        mov     byte [txf + 46], 50h    ; 20-byte header
        mov     ax, TCP_WINDOW
        xchg    al, ah
        mov     [txf + 48], ax
        mov     dword [txf + 50], 0     ; checksum and urgent pointer
        mov     di, txf + 54
        test    bl, TF_SYN              ; a SYN says how much we take: MSS
        jz      .data
        mov     byte [txf + 46], 60h
        mov     eax, 0B4050402h         ; 2, 4, 05B4h = 1460
        stosd
.data:  mov     cx, [seg_len]
        jcxz    .sum
        push    ds
        mov     si, [tx_off]
        mov     ds, [tx_seg]
        rep     movsb
        pop     ds
.sum:   mov     cx, di
        sub     cx, txf + 34
        mov     [seg_total], cx
        ; the checksum covers a pseudo-header: both addresses, protocol, length
        mov     eax, [my_ip]
        mov     [pseudo], eax
        mov     eax, [t_ip]
        mov     [pseudo + 4], eax
        mov     word [pseudo + 8], 0600h
        mov     ax, cx
        xchg    al, ah
        mov     [pseudo + 10], ax
        xor     edx, edx
        mov     si, pseudo
        mov     cx, 12
        call    csum_add
        mov     si, txf + 34
        mov     cx, [seg_total]
        call    csum_add
        call    csum_fold
        mov     [txf + 50], ax
        mov     byte [ip_proto], 6
        mov     eax, [t_ip]
        mov     si, t_mac
        mov     cx, [seg_total]
        jmp     ip_send

; hton32: EAX between host and network order (BSWAP is a 486's).
hton32: xchg    al, ah
        rol     eax, 16
        xchg    al, ah
        ret

; tcp_send: CX bytes from tx_seg:tx_off, a segment at a time, each
; acknowledged before the next goes. CF after saying so if it fails.
tcp_send:
        mov     [t_left], cx
.next:  cmp     word [t_left], 0
        je      .done
        mov     cx, [t_left]
        cmp     cx, [t_peer_mss]
        jbe     .size
        mov     cx, [t_peer_mss]
.size:  mov     [t_chunk], cx
        mov     byte [t_tries], 6
        mov     word [t_rto], 18
.send:  cmp     byte [t_state], T_OPEN
        jne     .lost
        mov     eax, [snd_una]
        mov     bl, TF_ACK | TF_PSH
        mov     cx, [t_chunk]
        call    tcp_segment
        movzx   eax, word [t_chunk]
        add     eax, [snd_una]
        mov     [snd_nxt], eax
        call    ticks
        mov     [t_start], ax
.wait:  mov     eax, [snd_una]          ; all of it acknowledged?
        cmp     eax, [snd_nxt]
        je      .acked
        cmp     byte [t_state], T_OPEN
        jne     .lost
        call    net_wait
        sub     ax, [t_start]
        cmp     ax, [t_rto]
        jb      .wait
        shl     word [t_rto], 1
        dec     byte [t_tries]
        jnz     .send
.lost:  mov     si, msg_tcp_lost
        call    print_err
        stc
        ret
.acked: mov     ax, [t_chunk]
        add     [tx_off], ax
        sub     [t_left], ax
        jmp     .next
.done:  clc
        ret

; tcp_input: a segment for our connection (or not).
tcp_input:
        cmp     byte [t_state], T_CLOSED
        je      .done
        mov     eax, [frame + 26]       ; from the other end of it?
        cmp     eax, [t_ip]
        jne     .done
        mov     ax, [frame + 34]
        cmp     ax, [t_rport]
        jne     .done
        mov     ax, [frame + 36]
        cmp     ax, [t_lport]
        jne     .done
        mov     al, [frame + 47]
        mov     [t_flags], al
        movzx   bx, byte [frame + 46]   ; its header length
        shr     bx, 4
        shl     bx, 2
        mov     ax, [ip_rx_plen]
        sub     ax, bx
        jb      .done
        mov     [t_plen], ax
        add     bx, frame + 34
        mov     [t_payload], bx
        mov     eax, [frame + 38]
        call    hton32
        mov     [t_seq], eax
        mov     eax, [frame + 42]
        call    hton32
        mov     [t_ack], eax

        test    byte [t_flags], TF_RST
        jz      .not_reset
        mov     byte [t_rst], 1
        mov     byte [t_state], T_CLOSED
        ret
.not_reset:
        cmp     byte [t_state], T_SYN_SENT
        jne     .open
        ; the answer to our SYN: SYN and ACK, acknowledging it
        mov     al, [t_flags]
        and     al, TF_SYN | TF_ACK
        cmp     al, TF_SYN | TF_ACK
        jne     .done
        mov     eax, [t_iss]
        inc     eax
        cmp     eax, [t_ack]
        jne     .done
        mov     [snd_una], eax
        mov     [snd_nxt], eax
        mov     eax, [t_seq]
        inc     eax
        mov     [rcv_nxt], eax
        cmp     byte [frame + 46], 60h  ; an MSS option, as everyone sends
        jb      .handshake_done
        cmp     word [frame + 54], 0402h
        jne     .handshake_done
        mov     ax, [frame + 56]
        xchg    al, ah
        cmp     ax, TCP_MSS
        jbe     .mss
        mov     ax, TCP_MSS
.mss:   mov     [t_peer_mss], ax
.handshake_done:
        mov     byte [t_state], T_OPEN
        jmp     .send_ack

.open:  test    byte [t_flags], TF_ACK
        jz      .done
        mov     eax, [t_ack]            ; what they have of ours
        sub     eax, [snd_una]
        jle     .data
        mov     eax, [t_ack]
        sub     eax, [snd_nxt]
        jg      .data                   ; more than we sent: ignore it
        mov     eax, [t_ack]
        mov     [snd_una], eax
.data:  cmp     word [t_plen], 0
        jne     .some
        test    byte [t_flags], TF_FIN
        jz      .done
.some:  mov     eax, [t_seq]            ; only the next bytes in order
        cmp     eax, [rcv_nxt]
        jne     .send_ack
        mov     cx, [t_plen]
        jcxz    .fin
        mov     ax, [http_max]          ; room for it?
        sub     ax, [http_len]
        cmp     cx, ax
        ja      .send_ack               ; no: they will send it again
        mov     si, [t_payload]
        mov     di, [http_len]
        push    es
        mov     es, [http_seg]
        rep     movsb
        pop     es
        mov     cx, [t_plen]
        add     [http_len], cx
        movzx   ecx, cx
        add     [rcv_nxt], ecx
.fin:   test    byte [t_flags], TF_FIN
        jz      .send_ack
        inc     dword [rcv_nxt]
        mov     byte [t_fin], 1
.send_ack:
        mov     eax, [snd_nxt]
        mov     bl, TF_ACK
        xor     cx, cx
        jmp     tcp_segment
.done:  ret

; tcp_close: our FIN, and a moment for it to be acknowledged.
tcp_close:
        cmp     byte [t_state], T_OPEN
        jne     .closed
        mov     eax, [snd_nxt]
        mov     bl, TF_FIN | TF_ACK
        xor     cx, cx
        call    tcp_segment
        inc     dword [snd_nxt]
        call    ticks
        mov     [t_start], ax
.wait:  mov     eax, [snd_una]
        cmp     eax, [snd_nxt]
        je      .closed
        cmp     byte [t_state], T_OPEN
        jne     .closed
        call    net_wait
        sub     ax, [t_start]
        cmp     ax, 18
        jb      .wait
.closed:
        mov     byte [t_state], T_CLOSED
        ret

; ------------------------------------------------------------
; HTTP
; ------------------------------------------------------------

; parse_url: http://host[:port][/path] at SI into url_host, url_port
; and url_path. CF after saying so if it is not one.
parse_url:
        mov     di, url_prefix
        mov     cx, 7
.p:     mov     al, [si]
        cmp     al, 'A'
        jb      .lower
        cmp     al, 'Z'
        ja      .lower
        add     al, 20h
.lower: cmp     al, [di]
        jne     .bad
        inc     si
        inc     di
        loop    .p
        mov     di, url_host
.h:     mov     al, [si]
        cmp     al, ':'
        je      .h_end
        cmp     al, '/'
        je      .h_end
        cmp     al, ' '
        jbe     .h_end
        cmp     di, url_host + NAME_MAX
        jae     .bad
        stosb
        inc     si
        jmp     .h
.h_end: mov     byte [di], 0
        cmp     di, url_host
        je      .bad
        mov     word [url_port], 80
        cmp     byte [si], ':'
        jne     .path
        inc     si
        call    parse_num
        jc      .bad
        mov     [url_port], ax
.path:  mov     di, url_path
        cmp     byte [si], '/'
        je      .copy
        mov     al, '/'
        stosb
.copy:  lodsb
        cmp     al, ' '
        jbe     .end
        cmp     di, url_path + LINE_MAX
        jae     .copy
        stosb
        jmp     .copy
.end:   mov     byte [di], 0
        clc
        ret
.bad:   mov     si, msg_bad_url
        call    print_err
        stc
        ret

; http_exchange: send the request in req_seg (req_len bytes) to the host
; in url_host/url_port and take the whole answer into http_seg (http_len
; bytes). The network must be open. CF after saying why if it fails.
http_exchange:
        mov     si, url_host
        call    host_ip
        jc      .fail
        mov     bx, [url_port]
        call    tcp_connect
        jc      .fail
        mov     ax, [req_seg]
        mov     [tx_seg], ax
        mov     ax, [req_start]
        mov     [tx_off], ax
        mov     cx, [req_len]
        call    tcp_send
        jc      .drop
        ; the answer: until they close, or HTTP_IDLE ticks of nothing
        call    ticks
        mov     [t_start], ax
        mov     ax, [http_len]
        mov     [t_seen], ax
.wait:  cmp     byte [t_fin], 0
        jne     .answered
        cmp     byte [t_state], T_OPEN
        jne     .answered
        call    net_wait
        mov     bx, [http_len]
        cmp     bx, [t_seen]
        je      .idle
        mov     [t_seen], bx
        mov     [t_start], ax
.idle:  sub     ax, [t_start]
        cmp     ax, HTTP_IDLE
        jb      .wait
        mov     si, msg_http_timeout
        call    print_err
.drop:  call    tcp_close
.fail:  stc
        ret
.answered:
        call    tcp_close
        cmp     byte [t_rst], 0
        je      .ok
        cmp     word [http_len], 0
        jne     .ok
        mov     si, msg_tcp_refused
        call    print_err
        stc
        ret
.ok:    clc
        ret

; http_buffers: memory from DOS for the request (req_seg) and the
; answer (http_seg). CF after saying so.
http_buffers:
        mov     bx, 1000h               ; 64 KB of request
        mov     ah, 48h
        int     21h
        jc      .none
        mov     [req_seg], ax
        mov     bx, HTTP_PARAS
        mov     ah, 48h
        int     21h
        jc      .free_req
        mov     [http_seg], ax
        mov     word [http_max], HTTP_PARAS * 16 - 1
        mov     word [http_len], 0
        mov     word [req_len], 0
        clc
        ret
.free_req:
        mov     es, [req_seg]
        mov     ah, 49h
        int     21h
        push    cs
        pop     es
        mov     word [req_seg], 0
.none:  mov     si, msg_net_memory
        call    print_err
        stc
        ret

; http_free: give them back (safe to call when there are none).
http_free:
        mov     ax, [req_seg]
        test    ax, ax
        jz      .answer
        mov     es, ax
        mov     ah, 49h
        int     21h
        mov     word [req_seg], 0
.answer:
        mov     ax, [http_seg]
        test    ax, ax
        jz      .done
        mov     es, ax
        mov     ah, 49h
        int     21h
        mov     word [http_seg], 0
.done:  push    cs
        pop     es
        ret

; req_add: the ASCIIZ string at SI onto the end of the request.
req_add:
        push    es
        mov     es, [req_seg]
        mov     di, [req_len]
.c:     lodsb
        test    al, al
        jz      .end
        stosb
        jmp     .c
.end:   mov     [req_len], di
        pop     es
        ret

; req_add_host: "Host: name" and its line end. The port is left out, as
; mTCP and ClauDOS send it: claude-p-shim matches the Host header exactly
; against its SHIM_HOSTS list, which names hosts without ports.
req_add_host:
        mov     si, hdr_host
        call    req_add
        mov     si, url_host
        call    req_add
        mov     si, crlf
        jmp     req_add

; FETCH url: an HTTP GET, the answer (headers and all) printed.
cmd_fetch:
        call    skip_blanks             ; the address as it is: its / are not switches
        cmp     byte [si], 0
        je      required_missing
        call    parse_url
        jc      .done
        call    last_fit
        call    http_buffers
        call    first_fit
        jc      .done
        mov     word [req_start], 0
        mov     si, http_get
        call    req_add
        mov     si, url_path
        call    req_add
        mov     si, http_10
        call    req_add
        call    req_add_host
        mov     si, crlf
        call    req_add
        call    net_open
        jc      .free
        call    http_exchange
        pushf
        call    net_close
        popf
        jc      .free
        ; print it as it is
        mov     cx, [http_len]
        mov     bx, 1
        xor     dx, dx
        push    ds
        mov     ds, [http_seg]
        mov     ah, 40h
        int     21h
        pop     ds
        mov     bx, [http_len]          ; a line end of our own only if it has none
        test    bx, bx
        jz      .free
        push    es
        mov     es, [http_seg]
        cmp     byte [es:bx - 1], 10
        pop     es
        je      .free
        call    newline
.free:  call    http_free
.done:  ret

        section .data
HTTP_IDLE       equ 18 * 120    ; two minutes without a byte: Claude can be slow
url_prefix      db 'http://'
http_get        db 'GET ', 0
http_10         db ' HTTP/1.0', 13, 10, 0
hdr_host        db 'Host: ', 0
msg_bad_url     db 'Not an http:// address', 13, 10, 0
msg_tcp_timeout db 'No answer from the host', 13, 10, 0
msg_tcp_refused db 'Connection refused', 13, 10, 0
msg_tcp_lost    db 'The connection was lost', 13, 10, 0
msg_http_timeout db 'The host stopped answering', 13, 10, 0

        section .bss
                alignb 4
t_ip            resd 1
t_iss           resd 1
snd_una         resd 1
snd_nxt         resd 1
rcv_nxt         resd 1
t_seq           resd 1
t_ack           resd 1
pseudo          resb 12
t_rport         resw 1
t_lport         resw 1
t_peer_mss      resw 1
t_rto           resw 1
t_start         resw 1
t_left          resw 1
t_chunk         resw 1
t_plen          resw 1
t_payload       resw 1
t_seen          resw 1
seg_len         resw 1
seg_total       resw 1
tx_seg          resw 1
tx_off          resw 1
req_seg         resw 1
req_len         resw 1
http_seg        resw 1
http_len        resw 1
http_max        resw 1
url_port        resw 1
t_state         resb 1
t_fin           resb 1
t_rst           resb 1
t_tries         resb 1
t_flags         resb 1
t_mac           resb 6
url_host        resb NAME_MAX + 2
url_path        resb LINE_MAX + 2
