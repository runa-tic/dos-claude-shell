; ============================================================
; net.asm - the network: a packet driver, Ethernet, ARP, IPv4,
; ICMP, UDP and DHCP; the NET and PING commands.
;
; The packet driver (Crynwr's NE2000.COM, or any other) is found
; by its "PKT DRVR" signature on INT 60h-80h. It is only held
; while a network command runs: net_open registers for IP and ARP
; frames and net_close lets go, so mTCP and other programs can
; use the card in between. What DHCP gave us is kept.
;
; Frames arrive in the driver's interrupt and are copied into a
; ring of slots in memory from DOS; net_poll takes them out and
; handles them one at a time in `frame`. Everything we send is
; built in `txf` (ARP replies in a small buffer of their own, as
; they can be sent while txf is being filled).
;
; IP addresses are kept as four bytes in network order, so a
; dword compare works; port numbers too, as they go on the wire.
; ============================================================
RING_SLOTS      equ 8           ; a power of two
SLOT_SIZE       equ 1536
FRAME_MAX       equ 1514

        section .text

; ------------------------------------------------------------
; The packet driver
; ------------------------------------------------------------

; find_driver: CF clear and pkt_vector set if there is a packet driver.
find_driver:
        mov     cx, 60h
.v:     xor     ax, ax
        mov     es, ax
        mov     bx, cx
        shl     bx, 2
        les     di, [es:bx]
        cmp     dword [es:di + 3], 'PKT '
        jne     .next
        cmp     dword [es:di + 7], 'DRVR'
        jne     .next
        mov     [pkt_vector], di
        mov     [pkt_vector + 2], es
        mov     [pkt_int], cl
        push    cs
        pop     es
        clc
        ret
.next:  inc     cx
        cmp     cx, 80h
        jbe     .v
        push    cs
        pop     es
        stc
        ret

; pkt_call: the packet driver function in AH, as if by its INT.
pkt_call:
        pushf
        call    far [cs:pkt_vector]
        ret

; net_open: hold the packet driver and have an address (DHCP if we have
; none yet). CF after saying why not.
net_open:
        cmp     byte [net_up], 0
        jne     .ok
        call    find_driver
        jnc     .found
        mov     si, msg_no_driver
        jmp     .fail
.found: call    last_fit
        mov     bx, (RING_SLOTS * SLOT_SIZE) / 16
        mov     ah, 48h
        int     21h
        call    first_fit
        jnc     .ring
        mov     si, msg_net_memory
        jmp     .fail
.ring:  mov     [ring_seg], ax
        xor     ax, ax
        mov     [ring_put], ax
        mov     [ring_get], ax
        mov     [ring_count], al
        mov     si, type_ip
        call    .access
        jc      .busy
        mov     [pkt_handle_ip], ax
        mov     si, type_arp
        call    .access
        jnc     .arp
        mov     bx, [pkt_handle_ip]
        mov     ah, 03h
        call    pkt_call
        jmp     .busy
.arp:   mov     [pkt_handle_arp], ax
        mov     bx, ax
        mov     di, my_mac
        mov     cx, 6
        mov     ah, 06h                 ; our hardware address
        call    pkt_call
        mov     byte [net_up], 1
        cmp     dword [my_ip], 0
        jne     .ok
        call    load_net_config
        cmp     dword [my_ip], 0
        jne     .ok
        call    dhcp
        jnc     .ok
        call    net_close
        mov     si, msg_no_dhcp
        jmp     .fail
.ok:    clc
        ret
.busy:  mov     es, [ring_seg]
        mov     ah, 49h
        int     21h
        push    cs
        pop     es
        mov     si, msg_driver_busy
.fail:  call    print_err
        stc
        ret
; access_type for the Ethernet type at SI: AX = the handle, CF if refused
.access:
        mov     ax, 0201h               ; access_type, class 1: Ethernet
        mov     bx, 0FFFFh              ; any type of card
        xor     dl, dl
        mov     cx, 2
        mov     di, pkt_receiver
        call    pkt_call
        ret

; net_close: let go of the packet driver.
net_close:
        cmp     byte [net_up], 0
        je      .done
        mov     bx, [pkt_handle_ip]
        mov     ah, 03h
        call    pkt_call
        mov     bx, [pkt_handle_arp]
        mov     ah, 03h
        call    pkt_call
        mov     es, [ring_seg]
        mov     ah, 49h
        int     21h
        push    cs
        pop     es
        mov     byte [net_up], 0
.done:  ret

; pkt_receiver: called by the packet driver, in its interrupt, for each
; frame. AX=0: CX bytes are coming, return ES:DI where to put them (0:0
; to drop it). AX=1: they are there.
pkt_receiver:
        test    ax, ax
        jnz     .filled
        cmp     cx, SLOT_SIZE
        ja      .drop
        cmp     byte [cs:ring_count], RING_SLOTS
        jae     .drop
        push    bx
        mov     bx, [cs:ring_put]
        shl     bx, 1
        mov     [cs:slot_len + bx], cx
        shr     bx, 1
        imul    di, bx, SLOT_SIZE
        mov     es, [cs:ring_seg]
        pop     bx
        retf
.drop:  xor     di, di
        mov     es, di
        retf
.filled:
        push    ax
        mov     ax, [cs:ring_put]
        inc     ax
        and     ax, RING_SLOTS - 1
        mov     [cs:ring_put], ax
        inc     byte [cs:ring_count]
        pop     ax
        retf

; send_frame: the CX bytes at SI out on the wire (short ones padded).
send_frame:
        cmp     cx, 60
        jae     .send
        mov     di, si
        add     di, cx
        push    cx
        neg     cx
        add     cx, 60
        xor     al, al
        rep     stosb
        pop     cx
        mov     cx, 60
.send:  mov     ah, 04h
        call    pkt_call
        ret

; net_poll: handle every frame that has come in.
net_poll:
        cmp     byte [ring_count], 0
        je      .done
        mov     bx, [ring_get]
        shl     bx, 1
        mov     cx, [slot_len + bx]
        mov     [frame_len], cx
        shr     bx, 1
        imul    si, bx, SLOT_SIZE
        cmp     cx, FRAME_MAX
        jbe     .copy
        mov     cx, FRAME_MAX
.copy:  mov     di, frame
        push    ds
        mov     ds, [ring_seg]
        rep     movsb
        pop     ds
        cli
        dec     byte [ring_count]
        sti
        mov     ax, [ring_get]
        inc     ax
        and     ax, RING_SLOTS - 1
        mov     [ring_get], ax
        call    handle_frame
        jmp     net_poll
.done:  ret

; net_wait: one turn of a waiting loop: frames in, and a chance for
; Ctrl-C (DOS looks for it on a status call). AX = the BIOS tick count.
net_wait:
        call    net_poll
        mov     ah, 0Bh
        int     21h
        jmp     ticks

; ticks: AX = the BIOS's 18.2-a-second tick count (its low word).
ticks:  push    es
        push    word 40h
        pop     es
        mov     ax, [es:6Ch]
        pop     es
        ret

handle_frame:
        mov     ax, [frame + 12]
        cmp     ax, 0608h               ; 08 06: ARP
        je      arp_input
        cmp     ax, 0008h               ; 08 00: IPv4
        je      ip_input
        ret

; ------------------------------------------------------------
; ARP
; ------------------------------------------------------------

arp_input:
        mov     ax, [frame + 20]        ; the operation
        cmp     ax, 0200h               ; a reply
        je      .reply
        cmp     ax, 0100h               ; a request: for us?
        jne     .done
        mov     eax, [frame + 38]
        cmp     dword [my_ip], 0
        je      .done
        cmp     eax, [my_ip]
        jne     .done
        mov     si, frame + 6           ; to whoever asked
        mov     di, arpf
        movsd
        movsw
        mov     si, my_mac
        movsd
        movsw
        mov     word [arpf + 12], 0608h
        mov     dword [arpf + 14], 00080100h    ; Ethernet, IPv4
        mov     word [arpf + 18], 0406h
        mov     word [arpf + 20], 0200h         ; reply
        mov     si, my_mac
        mov     di, arpf + 22
        movsd
        movsw
        mov     eax, [my_ip]
        mov     [arpf + 28], eax
        mov     si, frame + 22
        mov     di, arpf + 32
        movsd
        movsw
        mov     eax, [frame + 28]
        mov     [arpf + 38], eax
        mov     si, arpf
        mov     cx, 42
        jmp     send_frame
.reply: mov     eax, [frame + 28]
        cmp     eax, [arp_ip]
        jne     .done
        mov     si, frame + 22
        mov     di, arp_mac
        movsd
        movsw
        mov     byte [arp_ok], 1
.done:  ret

; arp_resolve: the hardware address for IP EAX (or for the gateway, if
; it is not on our network) into arp_mac. CF if nobody answers.
arp_resolve:
        mov     ebx, eax
        xor     ebx, [my_ip]
        and     ebx, [my_mask]
        jz      .direct
        mov     eax, [my_gw]
.direct:
        cmp     eax, [arp_ip]
        jne     .ask
        cmp     byte [arp_ok], 0
        jne     .ok
.ask:   mov     [arp_ip], eax
        mov     byte [arp_ok], 0
        mov     byte [arp_tries], 4
.try:   mov     di, arpf                ; who has arp_ip? (to everyone)
        mov     ax, 0FFFFh
        stosw
        stosw
        stosw
        mov     si, my_mac
        movsd
        movsw
        mov     word [arpf + 12], 0608h
        mov     dword [arpf + 14], 00080100h
        mov     word [arpf + 18], 0406h
        mov     word [arpf + 20], 0100h
        mov     si, my_mac
        mov     di, arpf + 22
        movsd
        movsw
        mov     eax, [my_ip]
        mov     [arpf + 28], eax
        mov     dword [arpf + 32], 0
        mov     word [arpf + 36], 0
        mov     eax, [arp_ip]
        mov     [arpf + 38], eax
        mov     si, arpf
        mov     cx, 42
        call    send_frame
        call    ticks
        mov     [arp_start], ax
.wait:  cmp     byte [arp_ok], 0
        jne     .ok
        call    net_wait
        sub     ax, [arp_start]
        cmp     ax, 9                   ; half a second
        jb      .wait
        dec     byte [arp_tries]
        jnz     .try
        stc
        ret
.ok:    clc
        ret

; ------------------------------------------------------------
; IP, ICMP, UDP
; ------------------------------------------------------------

; ip_send: the datagram whose payload (CX bytes, protocol ip_proto) is
; at txf + 34, to IP EAX, through the hardware address at SI.
ip_send:
        mov     [ip_dst], eax
        mov     [ip_plen], cx
        mov     di, txf
        movsd
        movsw
        mov     si, my_mac
        movsd
        movsw
        mov     word [txf + 12], 0008h
        mov     word [txf + 14], 0045h  ; version 4, 20-byte header, no TOS
        mov     ax, [ip_plen]
        add     ax, 20
        xchg    al, ah
        mov     [txf + 16], ax
        inc     word [ip_id]
        mov     ax, [ip_id]
        xchg    al, ah
        mov     [txf + 18], ax
        mov     word [txf + 20], 0
        mov     byte [txf + 22], 64     ; TTL
        mov     al, [ip_proto]
        mov     [txf + 23], al
        mov     word [txf + 24], 0
        mov     eax, [my_ip]
        mov     [txf + 26], eax
        mov     eax, [ip_dst]
        mov     [txf + 30], eax
        mov     si, txf + 14
        mov     cx, 20
        xor     edx, edx
        call    csum_add
        call    csum_fold
        mov     [txf + 24], ax
        mov     cx, [ip_plen]
        add     cx, 34
        mov     si, txf
        jmp     send_frame

; csum_add: the CX bytes at SI added into EDX, a word at a time.
; csum_fold: EDX folded into the Internet checksum in AX. The sum works
; in either byte order, so words are added as they lie in memory.
csum_add:
        shr     cx, 1
        pushf
        jcxz    .odd
.w:     lodsw
        movzx   eax, ax
        add     edx, eax
        loop    .w
.odd:   popf
        jnc     .done
        movzx   eax, byte [si]
        add     edx, eax
.done:  ret
csum_fold:
        mov     eax, edx
        shr     eax, 16
        add     dx, ax
        adc     dx, 0
        not     dx
        mov     ax, dx
        ret

ip_input:
        cmp     byte [frame + 14], 45h  ; IPv4 without options
        jne     .done
        mov     ax, [frame + 16]
        xchg    al, ah
        sub     ax, 20
        jb      .done
        mov     [ip_rx_plen], ax
        mov     eax, [frame + 30]       ; for us, for everyone, or anything
        cmp     eax, [my_ip]            ; while we have no address (DHCP)
        je      .ours
        cmp     eax, 0FFFFFFFFh
        je      .ours
        cmp     dword [my_ip], 0
        jne     .done
.ours:  mov     al, [frame + 23]
        cmp     al, 6
        je      tcp_input
        cmp     al, 17
        je      udp_input
        cmp     al, 1
        je      icmp_input
.done:  ret

icmp_input:
        cmp     byte [frame + 34], 0    ; an echo reply
        jne     .done
        mov     ax, [frame + 38]
        cmp     ax, [ping_id]
        jne     .done
        mov     ax, [frame + 40]
        cmp     ax, [ping_seq]
        jne     .done
        mov     byte [ping_got], 1
.done:  ret

udp_input:
        mov     ax, [frame + 36]        ; destination port
        cmp     ax, 4400h               ; 68: DHCP client
        je      dhcp_input
        cmp     ax, [dns_port]
        je      dns_input
        ret

; udp_send: the CX bytes at txf + 42 from port BX to port DX at IP
; udp_dst, through the hardware address at SI (ports in network order).
udp_send:
        mov     [txf + 34], bx
        mov     [txf + 36], dx
        add     cx, 8
        mov     ax, cx
        xchg    al, ah
        mov     [txf + 38], ax
        mov     word [txf + 40], 0      ; no checksum: allowed for UDP over IPv4
        mov     byte [ip_proto], 17
        mov     eax, [udp_dst]
        jmp     ip_send

; ------------------------------------------------------------
; DHCP
; ------------------------------------------------------------

; dhcp: an address, a gateway and a name server from a DHCP server.
; CF if none answered.
dhcp:
        call    ticks
        mov     [dhcp_xid], ax
        mov     [dhcp_xid + 2], ax
        mov     byte [dhcp_state], 1    ; waiting for an offer
        mov     byte [dhcp_tries], 4
.discover:
        mov     al, 1                   ; DHCPDISCOVER
        call    dhcp_send
        call    .wait
        cmp     byte [dhcp_state], 2
        je      .request
        dec     byte [dhcp_tries]
        jnz     .discover
        stc
        ret
.request:
        mov     byte [dhcp_tries], 4
.req:   mov     al, 3                   ; DHCPREQUEST
        call    dhcp_send
        call    .wait
        cmp     byte [dhcp_state], 3
        je      .bound
        dec     byte [dhcp_tries]
        jnz     .req
        stc
        ret
.bound: mov     byte [net_from_dhcp], 1
        clc
        ret
.wait:  mov     al, [dhcp_state]
        mov     [dhcp_was], al
        call    ticks
        mov     [arp_start], ax
.w:     call    net_wait
        mov     bl, [dhcp_state]
        cmp     bl, [dhcp_was]
        jne     .changed
        sub     ax, [arp_start]
        cmp     ax, 36                  ; two seconds
        jb      .w
.changed:
        ret

; dhcp_send: a DHCP message of type AL, to everyone.
dhcp_send:
        push    ax
        mov     di, txf + 42
        mov     cx, 300
        xor     al, al
        rep     stosb
        mov     dword [txf + 42], 00060101h     ; a request, Ethernet, 6-byte address
        mov     eax, [dhcp_xid]
        mov     [txf + 46], eax
        mov     word [txf + 52], 0080h          ; answer by broadcast: we have no address
        mov     si, my_mac
        mov     di, txf + 42 + 28
        movsd
        movsw
        mov     dword [txf + 42 + 236], 63538263h   ; the magic cookie
        mov     di, txf + 42 + 240
        pop     ax
        mov     ah, al
        mov     al, 53                  ; message type
        stosb
        mov     al, 1
        stosb
        mov     al, ah
        stosb
        cmp     ah, 3
        jne     .params
        mov     al, 50                  ; the address offered
        stosb
        mov     al, 4
        stosb
        mov     eax, [dhcp_offer]
        stosd
        mov     al, 54                  ; from the server that offered it
        stosb
        mov     al, 4
        stosb
        mov     eax, [dhcp_server]
        stosd
.params:
        mov     si, dhcp_params         ; 55: mask, router, name server; then the end
        mov     cx, dhcp_params_end - dhcp_params
        rep     movsb
        mov     dword [udp_dst], 0FFFFFFFFh
        mov     si, bcast_mac
        mov     bx, 4400h               ; from port 68
        mov     dx, 4300h               ; to port 67
        mov     cx, 300
        jmp     udp_send

dhcp_input:
        cmp     byte [frame + 42], 2    ; a reply
        jne     .done
        mov     eax, [frame + 46]
        cmp     eax, [dhcp_xid]
        jne     .done
        cmp     dword [frame + 42 + 236], 63538263h
        jne     .done
        ; the options
        mov     si, frame + 42 + 240
        mov     bx, frame
        add     bx, [frame_len]
        mov     byte [dhcp_type], 0
.opt:   cmp     si, bx
        jae     .options_read
        lodsb
        cmp     al, 255
        je      .options_read
        test    al, al                  ; padding
        jz      .opt
        mov     ah, al
        lodsb
        movzx   cx, al
        cmp     ah, 53
        jne     .not_type
        mov     al, [si]
        mov     [dhcp_type], al
.not_type:
        cmp     ah, 54
        jne     .not_server
        mov     eax, [si]
        mov     [dhcp_server], eax
.not_server:
        cmp     ah, 1
        jne     .not_mask
        mov     eax, [si]
        mov     [dhcp_mask], eax
.not_mask:
        cmp     ah, 3
        jne     .not_router
        mov     eax, [si]
        mov     [dhcp_gw], eax
.not_router:
        cmp     ah, 6
        jne     .next
        mov     eax, [si]
        mov     [dhcp_dns], eax
.next:  add     si, cx
        jmp     .opt
.options_read:
        mov     al, [dhcp_type]
        cmp     al, 2                   ; an offer
        jne     .ack
        cmp     byte [dhcp_state], 1
        jne     .done
        mov     eax, [frame + 42 + 16]
        mov     [dhcp_offer], eax
        mov     byte [dhcp_state], 2
        ret
.ack:   cmp     al, 5
        jne     .done
        cmp     byte [dhcp_state], 2
        jne     .done
        mov     eax, [frame + 42 + 16]
        mov     [my_ip], eax
        mov     eax, [dhcp_mask]
        mov     [my_mask], eax
        mov     eax, [dhcp_gw]
        mov     [my_gw], eax
        mov     eax, [dhcp_dns]
        mov     [my_dns], eax
        mov     byte [dhcp_state], 3
.done:  ret

; ------------------------------------------------------------
; Configuration: CLAUDE.CFG beside the shell
; ------------------------------------------------------------

; cfg_path: DI = the name of a file (SI) in the shell's own directory
; (C:\ if we do not know it), in pathbuf.
cfg_path:
        push    si
        mov     di, pathbuf
        cmp     byte [own_path], 0
        je      .root
        mov     si, own_path
        call    dir_prefix
        jmp     .name
.root:  mov     dword [pathbuf], 005C3A43h      ; "C:\", 0
        add     di, 3
.name:  pop     si
        jmp     append_z

; cfg_get: the value of "key=" (SI, lower case, with the '=') in
; CLAUDE.CFG, into DI (at most CX bytes). CF if there is none.
cfg_get:
        mov     [cfg_key], si
        mov     [cfg_dest], di
        mov     [cfg_max], cx
        mov     si, name_cfg
        call    cfg_path
        mov     dx, pathbuf
        mov     ax, 3D00h
        int     21h
        jc      .none
        mov     bx, ax
        mov     dx, cfgbuf
        mov     cx, CFGBUF_SIZE - 1
        mov     ah, 3Fh
        int     21h
        jnc     .read
        xor     ax, ax
.read:  push    ax
        mov     ah, 3Eh
        int     21h
        pop     bx
        mov     byte [cfgbuf + bx], 0
        mov     si, cfgbuf
.line:  call    skip_blanks
        mov     di, [cfg_key]           ; does this line start with the key?
        push    si
.k:     mov     al, [di]
        test    al, al
        jz      .match
        mov     ah, [si]
        cmp     ah, 'A'
        jb      .cmp
        cmp     ah, 'Z'
        ja      .cmp
        add     ah, 20h
.cmp:   cmp     al, ah
        jne     .skip
        inc     si
        inc     di
        jmp     .k
.match: add     sp, 2
        mov     di, [cfg_dest]
        mov     cx, [cfg_max]
.v:     lodsb
        cmp     al, ' '
        jb      .v_end
        stosb
        loop    .v
.v_end: dec     di                      ; trailing blanks off
        cmp     di, [cfg_dest]
        jb      .v_done
        cmp     byte [di], ' '
        je      .v_end
.v_done:
        mov     byte [di + 1], 0
        clc
        ret
.skip:  pop     si
.eol:   lodsb
        test    al, al
        jz      .none
        cmp     al, 10
        jne     .eol
        jmp     .line
.none:  stc
        ret

; load_net_config: ip=, mask=, gateway=, dns= from CLAUDE.CFG, if there.
load_net_config:
        mov     si, key_ip
        mov     di, valbuf
        mov     cx, 20
        call    cfg_get
        jc      .done
        mov     si, valbuf
        call    parse_ip
        jc      .done                   ; "ip=dhcp", or anything else: DHCP
        mov     [my_ip], eax
        mov     dword [my_mask], 00FFFFFFh      ; 255.255.255.0
        mov     si, key_mask
        mov     bx, my_mask
        call    .one
        mov     si, key_gateway
        mov     bx, my_gw
        call    .one
        mov     si, key_dns
        mov     bx, my_dns
        call    .one
        mov     byte [net_from_dhcp], 0
.done:  ret
.one:   push    bx
        mov     di, valbuf
        mov     cx, 20
        call    cfg_get
        pop     bx
        jc      .no
        mov     si, valbuf
        push    bx
        call    parse_ip
        pop     bx
        jc      .no
        mov     [bx], eax
.no:    ret

; parse_ip: a dotted address at SI into EAX (network order); CF if not one.
parse_ip:
        xor     edx, edx
        mov     byte [ip_parts], 0
.part:  push    edx
        call    parse_num
        pop     edx
        jc      .bad
        cmp     ax, 255
        ja      .bad
        shrd    edx, eax, 8             ; the byte in at the top; four of them end in order
        inc     byte [ip_parts]
        cmp     byte [ip_parts], 4
        je      .end
        cmp     byte [si], '.'
        jne     .bad
        inc     si
        jmp     .part
.end:   mov     eax, edx
        clc
        ret
.bad:   stc
        ret

; print_ip: the address EAX as a.b.c.d.
print_ip:
        mov     [ip_print], eax
        xor     bx, bx
.b:     push    bx
        movzx   ax, byte [ip_print + bx]
        call    put_dec
        pop     bx
        inc     bx
        cmp     bx, 4
        je      .done
        mov     dl, '.'
        call    putc
        jmp     .b
.done:  ret

; ------------------------------------------------------------
; DNS
; ------------------------------------------------------------

; host_ip: the address of the host at SI, a dotted address or a name
; asked of the name server. EAX; CF after saying so if there is none.
host_ip:
        push    si
        call    parse_ip
        pop     si
        jc      dns_lookup
        ret

; dns_lookup: the A record for the name at SI. The network is open.
dns_lookup:
        mov     [dns_name], si
        mov     eax, [my_dns]
        test    eax, eax
        jz      .unknown
        call    arp_resolve
        jc      .unknown
        mov     si, arp_mac
        mov     di, dns_mac
        movsd
        movsw
        call    ticks
        mov     [dns_id], ax
        or      ah, 80h                 ; our port, from the clock: 32768 and up
        xchg    al, ah
        mov     [dns_port], ax
        mov     byte [dns_tries], 3
.ask:   mov     byte [dns_got], 0
        ; the query: id, recursion wanted, one question
        mov     di, txf + 42
        mov     ax, [dns_id]
        stosw
        mov     ax, 0001h               ; 01 00
        stosw
        mov     ax, 0100h               ; 00 01: one question
        stosw
        xor     ax, ax
        stosw
        stosw
        stosw
        mov     si, [dns_name]          ; www.example.com as 3www7example3com0
.label: mov     bx, di                  ; where this label's length goes
        inc     di
.ch:    lodsb
        cmp     al, '.'
        je      .label_end
        cmp     al, ' '
        jbe     .label_end
        stosb
        jmp     .ch
.label_end:
        mov     cx, di
        sub     cx, bx
        dec     cx
        mov     [bx], cl
        cmp     al, '.'
        je      .label
        xor     al, al
        stosb
        mov     eax, 01000100h          ; type A, class IN
        stosd
        mov     cx, di
        sub     cx, txf + 42
        mov     eax, [my_dns]
        mov     [udp_dst], eax
        mov     si, dns_mac
        mov     bx, [dns_port]
        mov     dx, 3500h               ; port 53
        call    udp_send
        call    ticks
        mov     [arp_start], ax
.wait:  cmp     byte [dns_got], 0
        jne     .answered
        call    net_wait
        sub     ax, [arp_start]
        cmp     ax, 36
        jb      .wait
        dec     byte [dns_tries]
        jnz     .ask
.unknown:
        mov     si, msg_unknown_host
        call    print_err
        stc
        ret
.answered:
        cmp     byte [dns_got], 1
        jne     .unknown
        mov     eax, [dns_answer]
        clc
        ret

; dns_input: an answer to our query: the first A record in it.
dns_input:
        mov     ax, [frame + 42]
        cmp     ax, [dns_id]
        jne     .done
        mov     byte [dns_got], 2       ; answered, but maybe with nothing
        test    byte [frame + 45], 0Fh  ; an error code
        jnz     .done
        mov     cx, [frame + 48]        ; answers
        xchg    cl, ch
        jcxz    .done
        mov     si, frame + 54          ; past the header: skip the question
        call    .skip_name
        add     si, 4
.answer:
        call    .skip_name
        mov     ax, [si]                ; type
        mov     bx, [si + 8]            ; data length
        xchg    bl, bh
        add     si, 10
        cmp     ax, 0100h               ; A
        jne     .next
        cmp     bx, 4
        jne     .next
        mov     eax, [si]
        mov     [dns_answer], eax
        mov     byte [dns_got], 1
        ret
.next:  add     si, bx
        loop    .answer
.done:  ret
.skip_name:
        lodsb
        test    al, al
        jz      .skipped
        cmp     al, 0C0h                ; a pointer ends the name
        jae     .pointer
        movzx   ax, al
        add     si, ax
        jmp     .skip_name
.pointer:
        inc     si
.skipped:
        ret

; ------------------------------------------------------------
; NET and PING
; ------------------------------------------------------------

; NET: the card and the address, getting one if need be.
cmd_net:
        call    net_open
        jc      .done
        mov     si, msg_net_driver
        call    print_z
        mov     al, [pkt_int]
        call    put_hex8
        mov     si, msg_net_mac
        call    print_z
        xor     bx, bx
.mac:   push    bx
        mov     al, [my_mac + bx]
        call    put_hex8
        pop     bx
        inc     bx
        cmp     bx, 6
        je      .mac_done
        mov     dl, ':'
        call    putc
        jmp     .mac
.mac_done:
        call    newline
        mov     si, msg_net_ip
        call    print_z
        mov     eax, [my_ip]
        call    print_ip
        mov     si, msg_net_mask
        call    print_z
        mov     eax, [my_mask]
        call    print_ip
        call    newline
        mov     si, msg_net_gw
        call    print_z
        mov     eax, [my_gw]
        call    print_ip
        mov     si, msg_net_dns
        call    print_z
        mov     eax, [my_dns]
        call    print_ip
        mov     si, msg_net_static
        cmp     byte [net_from_dhcp], 0
        je      .how
        mov     si, msg_net_dhcp
.how:   call    print_z
        call    net_close
.done:  ret

; PING address: four echo requests, a second apart at most.
cmd_ping:
        call    parse_args
        cmp     word [argc], 0
        je      required_missing
        call    net_open
        jc      .done
        mov     si, [argv]
        call    host_ip
        jc      .close
        mov     [ping_ip], eax
        call    arp_resolve
        jnc     .resolved
        mov     si, msg_no_route
        call    print_err
        jmp     .close
.resolved:
        mov     si, arp_mac
        mov     di, ping_mac
        movsd
        movsw
        mov     word [ping_id], 3412h
        mov     word [ping_sent], 0
        mov     word [ping_recv], 0
        mov     word [ping_seq], 0
.one:   mov     ax, [ping_seq]
        xchg    al, ah
        inc     ax
        xchg    al, ah
        mov     [ping_seq], ax
        mov     byte [ping_got], 0
        ; the echo request: type 8, code 0, checksum, id, sequence, 32 bytes
        mov     word [txf + 34], 0008h
        mov     word [txf + 36], 0
        mov     ax, [ping_id]
        mov     [txf + 38], ax
        mov     ax, [ping_seq]
        mov     [txf + 40], ax
        mov     di, txf + 42
        mov     al, 'a'
        mov     cx, 32
.fill:  stosb
        inc     al
        loop    .fill
        mov     si, txf + 34
        mov     cx, 40
        xor     edx, edx
        call    csum_add
        call    csum_fold
        mov     [txf + 36], ax
        mov     byte [ip_proto], 1
        mov     eax, [ping_ip]
        mov     si, ping_mac
        mov     cx, 40
        call    ip_send
        inc     word [ping_sent]
        call    ticks
        mov     [ping_start], ax
.wait:  cmp     byte [ping_got], 0
        jne     .reply
        call    net_wait
        sub     ax, [ping_start]
        cmp     ax, 18
        jb      .wait
        mov     si, msg_ping_timeout
        call    print_z
        jmp     .next
.reply: inc     word [ping_recv]
        call    ticks
        sub     ax, [ping_start]
        mov     [ping_time], ax
        mov     si, msg_ping_reply
        call    print_z
        mov     eax, [ping_ip]
        call    print_ip
        mov     si, msg_ping_time
        call    print_z
        mov     ax, [ping_time]
        imul    ax, ax, 55
        test    ax, ax
        jnz     .ms
        mov     si, msg_ping_fast
        call    print_z
        jmp     .ms_done
.ms:    call    put_dec
        mov     si, msg_ms
        call    print_z
.ms_done:
        call    ticks                   ; a second between them
        mov     [ping_start], ax
.pause: call    net_wait
        sub     ax, [ping_start]
        cmp     ax, 9
        jb      .pause
.next:  cmp     word [ping_sent], 4
        jb      .one
        mov     si, msg_ping_sum1
        call    print_z
        mov     ax, [ping_sent]
        call    put_dec
        mov     si, msg_ping_sum2
        call    print_z
        mov     ax, [ping_recv]
        call    put_dec
        call    newline
.close: call    net_close
.done:  ret

        section .data
type_ip         db 08h, 00h
type_arp        db 08h, 06h
bcast_mac       db 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
dhcp_params     db 55, 3, 1, 3, 6, 255
dhcp_params_end:
name_cfg        db 'CLAUDE.CFG', 0
key_ip          db 'ip=', 0
key_mask        db 'mask=', 0
key_gateway     db 'gateway=', 0
key_dns         db 'dns=', 0
msg_no_driver   db 'No packet driver (load one, such as NE2000.COM, first)', 13, 10, 0
msg_driver_busy db 'The packet driver is in use by another program', 13, 10, 0
msg_net_memory  db 'Not enough memory for the network', 13, 10, 0
msg_no_dhcp     db 'No answer from DHCP: set ip= in CLAUDE.CFG', 13, 10, 0
msg_no_route    db 'No answer to ARP: the host or gateway is not there', 13, 10, 0
msg_net_driver  db 'Packet driver on INT ', 0
msg_net_mac     db 'h, hardware address ', 0
msg_net_ip      db 'IP ', 0
msg_net_mask    db ', mask ', 0
msg_net_gw      db 'Gateway ', 0
msg_net_dns     db ', name server ', 0
msg_net_dhcp    db ' (from DHCP)', 13, 10, 0
msg_net_static  db ' (from CLAUDE.CFG)', 13, 10, 0
msg_unknown_host db 'Unknown host', 13, 10, 0
msg_ping_reply  db 'Reply from ', 0
msg_ping_time   db ': bytes=32 time', 0
msg_ping_fast   db '<55ms', 13, 10, 0
msg_ms          db 'ms', 13, 10, 0
msg_ping_timeout db 'Request timed out', 13, 10, 0
msg_ping_sum1   db 'Sent ', 0
msg_ping_sum2   db ', received ', 0

        section .bss
                alignb 4
pkt_vector      resd 1
my_ip           resd 1
my_mask         resd 1
my_gw           resd 1
my_dns          resd 1
arp_ip          resd 1
ip_dst          resd 1
udp_dst         resd 1
ip_print        resd 1
ping_ip         resd 1
dhcp_xid        resd 1
dhcp_offer      resd 1
dhcp_server     resd 1
dhcp_mask       resd 1
dhcp_gw         resd 1
dhcp_dns        resd 1
dns_answer      resd 1
ring_seg        resw 1
ring_put        resw 1
ring_get        resw 1
slot_len        resw RING_SLOTS
frame_len       resw 1
pkt_handle_ip   resw 1
pkt_handle_arp  resw 1
ip_plen         resw 1
ip_rx_plen      resw 1
ip_id           resw 1
arp_start       resw 1
ping_id         resw 1
ping_seq        resw 1
ping_sent       resw 1
ping_recv       resw 1
ping_start      resw 1
ping_time       resw 1
cfg_key         resw 1
dns_name        resw 1
dns_id          resw 1
dns_port        resw 1
cfg_dest        resw 1
cfg_max         resw 1
ring_count      resb 1
net_up          resb 1
net_from_dhcp   resb 1
pkt_int         resb 1
arp_ok          resb 1
arp_tries       resb 1
ip_proto        resb 1
ping_got        resb 1
dhcp_state      resb 1
dhcp_was        resb 1
dhcp_tries      resb 1
dhcp_type       resb 1
ip_parts        resb 1
dns_got         resb 1
dns_tries       resb 1
dns_mac         resb 6
my_mac          resb 6
arp_mac         resb 6
ping_mac        resb 6
CFGBUF_SIZE     equ 512
cfgbuf          resb CFGBUF_SIZE
arpf            resb 64
frame           resb FRAME_MAX + 2
txf             resb FRAME_MAX + 2
