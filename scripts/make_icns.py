#!/usr/bin/env python3
"""Builds a valid .icns from PNGs without needing Apple's iconutil.

Modern macOS (10.7+) accepts PNG-encoded members, so an .icns is just a
container: 'icns' + big-endian total length, then (type, length, data) chunks.
Usage: make_icns.py OUT.icns SIZE=path.png [SIZE=path.png ...]
"""
import struct
import sys

# icon type codes keyed by pixel size (we use the @1x codes; @2x codes point at the same pixels)
TYPES = {
    16: b"icp4", 32: b"icp5", 64: b"icp6", 128: b"ic07",
    256: b"ic08", 512: b"ic09", 1024: b"ic10",
}
RETINA = {32: b"ic11", 64: b"ic12", 256: b"ic13", 512: b"ic14"}


def main() -> None:
    out = sys.argv[1]
    chunks = []
    for arg in sys.argv[2:]:
        size, path = arg.split("=", 1)
        size = int(size)
        data = open(path, "rb").read()
        for code in filter(None, [TYPES.get(size), RETINA.get(size)]):
            chunks.append(code + struct.pack(">I", 8 + len(data)) + data)
    body = b"".join(chunks)
    with open(out, "wb") as f:
        f.write(b"icns" + struct.pack(">I", 8 + len(body)) + body)
    print(f"wrote {out} ({8 + len(body)} bytes, {len(chunks)} members)")


if __name__ == "__main__":
    main()
