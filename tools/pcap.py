#!/usr/bin/env python3
"""One line per frame of a pcap written by QEMU's filter-dump (build/net.pcap)."""
import struct
import sys

DHCP = {1: "DISCOVER", 2: "OFFER", 3: "REQUEST", 5: "ACK", 6: "NAK"}


def ip(b):
    return ".".join(str(x) for x in b)


def describe(f):
    ethertype = struct.unpack_from(">H", f, 12)[0]
    if ethertype == 0x0806:
        op = struct.unpack_from(">H", f, 20)[0]
        return f"ARP {'request' if op == 1 else 'reply'} {ip(f[28:32])} -> {ip(f[38:42])}"
    if ethertype != 0x0800:
        return f"ethertype {ethertype:04x}"
    header = (f[14] & 0x0F) * 4
    proto, src, dst = f[23], ip(f[26:30]), ip(f[30:34])
    p = f[14 + header:]
    if proto == 1:
        return f"ICMP {src} -> {dst} type {p[0]} seq {struct.unpack_from('>H', p, 6)[0]}"
    if proto == 17:
        sport, dport = struct.unpack_from(">HH", p, 0)
        text = f"UDP {src}:{sport} -> {dst}:{dport}"
        if {sport, dport} & {67, 68}:
            body, kind, i = p[8:], None, 240
            while i + 1 < len(body) and body[i] != 255:
                if body[i] == 0:
                    i += 1
                    continue
                if body[i] == 53:
                    kind = body[i + 2]
                i += 2 + body[i + 1]
            text += f" DHCP {DHCP.get(kind, kind)} xid {body[4:8].hex()}"
        return text
    if proto == 6:
        sport, dport, seq, ack = struct.unpack_from(">HHII", p, 0)
        flags = "".join(n for bit, n in ((2, "S"), (16, "A"), (8, "P"), (1, "F"), (4, "R")) if p[13] & bit)
        size = struct.unpack_from(">H", f, 16)[0] - header - (p[12] >> 4) * 4     # not len(f): short frames are padded
        return f"TCP {src}:{sport} -> {dst}:{dport} [{flags}] seq {seq} ack {ack} win {struct.unpack_from('>H', p, 14)[0]} len {size}"
    return f"IP {src} -> {dst} proto {proto}"


def main():
    data = open(sys.argv[1] if len(sys.argv) > 1 else "build/net.pcap", "rb").read()
    off, first = 24, None
    while off + 16 <= len(data):
        sec, usec, caplen, _ = struct.unpack_from("<IIII", data, off)
        frame = data[off + 16:off + 16 + caplen]
        off += 16 + caplen
        t = sec + usec / 1e6
        first = t if first is None else first
        print(f"{t - first:8.3f}s {caplen:5d}  {describe(frame)}")


if __name__ == "__main__":
    main()
