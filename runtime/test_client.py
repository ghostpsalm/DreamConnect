#!/usr/bin/env python3
"""Exercises the dreamconnect daemon the way the Java agent will: read the shm
frame via the seqlock, query geometry, inject input. Validation harness."""
import mmap
import os
import socket
import struct
import sys

SHM = "/dev/shm/dreamconnect.frame"
SOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid()),
                    "dreamconnect.sock")


def cmd(sock, line):
    """Control command: send and read the one-line reply."""
    sock.sendall((line + "\n").encode())
    return sock.makefile("rb").readline().decode().strip()


def fire(sock, line):
    """Input command: fire-and-forget (the daemon sends no reply)."""
    sock.sendall((line + "\n").encode())
    return "(sent)"


def read_frame():
    fd = os.open(SHM, os.O_RDONLY)
    size = os.fstat(fd).st_size
    mm = mmap.mmap(fd, size, prot=mmap.PROT_READ)
    magic, ver, w, h, stride, fmt = struct.unpack_from("<4sIIIII", mm, 0)
    assert magic == b"DCF1", magic
    # seqlock read: retry until begin == end (no torn frame)
    for _ in range(50):
        end = struct.unpack_from("<Q", mm, 32)[0]
        data = bytes(mm[64:64 + stride * h])
        begin = struct.unpack_from("<Q", mm, 24)[0]
        if begin == end and begin != 0:
            break
    return w, h, stride, fmt, begin, data


def main():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    print("PING ->", cmd(s, "PING"))
    print("GEOM ->", cmd(s, "GEOM"))
    print("NODE ->", cmd(s, "NODE"))

    w, h, stride, fmt, seq, data = read_frame()
    print(f"frame {w}x{h} stride={stride} fmt={fmt} seq={seq} bytes={len(data)}")
    # BGRx -> check non-black by luminance range
    try:
        from PIL import Image
        img = Image.frombytes("RGBX", (w, h), data, "raw", "BGRX")
        img = img.convert("RGB")
        ex = img.convert("L").getextrema()
        out = "/tmp/dreamconnect_client_frame.png"
        img.save(out)
        print(f"luma range {ex} -> {'NON-BLACK' if ex[1] > 10 else 'BLACK!'} saved {out}")
    except ImportError:
        nz = sum(1 for b in data[:100000] if b)
        print(f"first-100k nonzero bytes: {nz}")

    # input: move to two points, left click, type 'a' via evdev keycode 30
    # (fire-and-forget — no reply expected)
    print("M 200 200 ->", fire(s, "M 200 200"))
    print("M 960 540 ->", fire(s, "M 960 540"))
    print("B left press ->", fire(s, "B 272 1"))
    print("B left release ->", fire(s, "B 272 0"))
    print("K a press ->", fire(s, "K 30 1"))
    print("K a release ->", fire(s, "K 30 0"))
    # confirm the socket is still aligned: a control command still replies
    print("PING (post-input) ->", cmd(s, "PING"))


if __name__ == "__main__":
    sys.exit(main())
