#!/usr/bin/env python3
"""Generate a tasteful DMG background for murmur installer."""

import struct, zlib, math, sys

W, H = 660, 420
OUT = sys.argv[1] if len(sys.argv) > 1 else "dmg-background.png"

def make_png(width, height, pixels):
    def chunk(tag, data):
        c = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', c)

    raw = b''
    for y in range(height):
        raw += b'\x00'
        for x in range(width):
            raw += bytes(pixels[y][x])

    compressed = zlib.compress(raw, 9)
    png  = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', compressed)
    png += chunk(b'IEND', b'')
    return png

# Build pixel grid
pixels = []
for y in range(H):
    row = []
    for x in range(W):
        # Base: very dark #141416
        base_r, base_g, base_b = 0x14, 0x14, 0x16

        # Subtle radial glow — warm indigo at bottom-left
        dx1 = x / W - 0.15
        dy1 = y / H - 0.85
        d1 = math.sqrt(dx1*dx1 + dy1*dy1)
        glow1 = max(0.0, 1.0 - d1 / 0.5) ** 2.2
        glow1 *= 0.18

        # Cool blue glow at top-right
        dx2 = x / W - 0.88
        dy2 = y / H - 0.10
        d2 = math.sqrt(dx2*dx2 + dy2*dy2)
        glow2 = max(0.0, 1.0 - d2 / 0.45) ** 2.5
        glow2 *= 0.12

        r = int(min(255, base_r + glow1 * 60  + glow2 * 20))
        g = int(min(255, base_g + glow1 * 30  + glow2 * 40))
        b = int(min(255, base_b + glow1 * 90  + glow2 * 80))
        row.append((r, g, b))
    pixels.append(row)

with open(OUT, 'wb') as f:
    f.write(make_png(W, H, pixels))

print(f"Written {OUT} ({W}x{H})")
