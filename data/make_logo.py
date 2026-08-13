#!/usr/bin/env python3
"""Render the Karaoke Bar Map logo (map pin + mic) to PNGs with PIL.
Matches public/logo.svg. Outputs logo.png (512) + favicon PNGs."""
import os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), '..', 'public')
S = 512
PURPLE = (124, 58, 237)   # #7C3AED
MAGENTA = (255, 61, 139)  # #FF3D8B


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def render(size):
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # --- teardrop pin mask (circle head + triangle point) ---
    mask = Image.new('L', (S, S), 0)
    m = ImageDraw.Draw(mask)
    cx, cy, r = 256, 196, 172
    m.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    m.polygon([(cx - 150, 300), (cx + 150, 300), (cx, 492)], fill=255)

    # --- diagonal gradient, clipped to the pin ---
    grad = Image.new('RGBA', (S, S))
    gp = grad.load()
    for y in range(S):
        for x in range(S):
            gp[x, y] = lerp(PURPLE, MAGENTA, (x + y) / (2 * (S - 1))) + (255,)
    img.paste(grad, (0, 0), mask)

    # --- microphone (white) ---
    d.rounded_rectangle([208, 96, 304, 264], radius=48, fill=(255, 255, 255, 255))   # capsule
    d.rounded_rectangle([244, 260, 268, 332], radius=12, fill=(255, 255, 255, 255))  # stand
    d.rounded_rectangle([192, 324, 320, 351], radius=13, fill=(255, 255, 255, 255))  # base
    for yy in (144, 176, 208):   # grille lines
        d.line([(228, yy), (284, yy)], fill=PURPLE + (150,), width=11)

    if size != S:
        img = img.resize((size, size), Image.LANCZOS)
    return img


render(512).save(os.path.join(OUT, 'logo.png'))
render(180).save(os.path.join(OUT, 'apple-touch-icon.png'))
render(32).save(os.path.join(OUT, 'favicon-32.png'))
print('wrote logo.png (512), apple-touch-icon.png (180), favicon-32.png (32)')
