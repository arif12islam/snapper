#!/usr/bin/env python3
"""Renders every Snapper icon from the two SVGs, aligned to the pixel grid at each size.
Needs: pip install cairosvg pillow.   Run from the design folder:  python3 make_icons.py
Writes ../Snapper/Resources/{AppIcon.iconset/, MenuBarIcon.png, MenuBarIcon@2x.png, BrandBadge.png, BrandBadge@2x.png}
"""
import io, os, re
import cairosvg
from PIL import Image, ImageFilter, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, '..', 'Snapper', 'Resources')
os.makedirs(os.path.join(RES, 'AppIcon.iconset'), exist_ok=True)

def svg_square(name, px):
    """Renders an SVG with its rounded badge turned into a full square (we apply our own mask)."""
    src = open(os.path.join(HERE, name)).read()
    src = re.sub(r'rx="360"', 'rx="0"', src)
    png = cairosvg.svg2png(bytestring=src.encode(), output_width=px, output_height=px)
    return Image.open(io.BytesIO(png)).convert('RGBA')

def squircle_mask(px, n=5.0):
    """Apple-style continuous-corner (superellipse) mask, px x px."""
    k = 4
    big = px * k
    m = Image.new('L', (big, big), 0)
    pix = m.load()
    r = big / 2.0
    for y in range(big):
        dy = abs((y + 0.5 - r) / r)
        # solve |x|^n + |y|^n <= 1
        rem = 1 - dy ** n
        if rem <= 0:
            continue
        dx = rem ** (1.0 / n)
        x0 = int(round(r - dx * r)); x1 = int(round(r + dx * r))
        for x in range(max(0, x0), min(big, x1)):
            pix[x, y] = 255
    return m.resize((px, px), Image.LANCZOS)

def thickened(name, px, grow, invert=False, gap=0):
    """Small-size hinting: widens only the snail's body and antennae by `grow` pixels (at render size),
    so they survive at 16-32 px. The lens ring is left exactly as drawn."""
    from PIL import ImageDraw
    art = svg_square(name, px)
    lum = art.convert('L')
    glyph = ImageChops.invert(lum) if invert else lum           # 255 where the glyph is
    glyph = glyph.point(lambda v: 255 if v > 127 else 0)
    # Separate the ring from the snail: flood-fill the ring (seed on its right side) with 128.
    tagged = glyph.copy()
    seed = (int(px * 0.80), int(px * 0.50))
    if tagged.getpixel(seed) == 255:
        ImageDraw.floodfill(tagged, seed, 128)
    ring = tagged.point(lambda v: 255 if v == 128 else 0)
    snail = tagged.point(lambda v: 255 if v == 255 else 0)
    if grow >= 1:
        snail = snail.filter(ImageFilter.MaxFilter(int(grow) * 2 + 1))
    if gap >= 1:
        # Keep a clear band between the snail and the ring so they never merge.
        keepout = ring.filter(ImageFilter.MaxFilter(int(gap) * 2 + 1))
        snail = ImageChops.subtract(snail, keepout)
    return ImageChops.lighter(ring, snail)

def app_icon(size):
    ss = 8 if size <= 64 else (4 if size <= 256 else 2)
    S = size * ss
    # Apple grid: 824/1024 body, snapped so the margin is a whole number of output pixels.
    body = round(size * 824 / 1024)
    if (size - body) % 2: body += 1
    off = (size - body) // 2
    B, O = body * ss, off * ss
    if size <= 32:
        grow = {16: 5, 32: 2}[size] * ss // 8          # ~0.6 px at 16, 0.25 px at 32
        g = thickened('main_icon.svg', B, grow, gap={16: ss, 32: ss // 2}[size])
        content = Image.new('RGBA', (B, B), (0x1B, 0x1B, 0x4D, 255))
        content.paste(Image.new('RGBA', (B, B), (255, 255, 255, 255)), (0, 0), g)
    else:
        content = svg_square('main_icon.svg', B)
    mask = squircle_mask(B)
    badge = Image.new('RGBA', (B, B), (0, 0, 0, 0))
    badge.paste(content, (0, 0), mask)
    canvas = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    if size >= 64:
        # Soft drop shadow like the system icons.
        sh = Image.new('RGBA', (S, S), (0, 0, 0, 0))
        shadow_alpha = Image.new('L', (S, S), 0)
        shadow_alpha.paste(mask.point(lambda a: int(a * 0.32)), (O, O + int(S * 0.012)))
        shadow_alpha = shadow_alpha.filter(ImageFilter.GaussianBlur(S * 0.018))
        sh.putalpha(shadow_alpha)
        canvas = Image.alpha_composite(canvas, sh)
    layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    layer.paste(badge, (O, O), badge)
    canvas = Image.alpha_composite(canvas, layer)
    out = canvas.resize((size, size), Image.BOX if ss >= 8 else Image.LANCZOS)
    if size <= 32:
        out = out.filter(ImageFilter.UnsharpMask(radius=0.6, percent=60, threshold=0))
    return out

def badge(size, inset=0):
    """Full-bleed squircle badge (logo) for in-app use: toasts, HUDs, About."""
    ss = 8
    S = size * ss
    content = svg_square('main_icon.svg', S)
    mask = squircle_mask(S)
    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    out.paste(content, (0, 0), mask)
    return out.resize((size, size), Image.BOX)

def menubar(px):
    """White badge with the glyph knocked out, snapped to whole pixels. 18 pt menu bar slot."""
    ss = 8
    body = 16 if px == 18 else 32           # leaves 1 pt above and below
    off = (px - body) // 2
    B, S, O = body * ss, px * ss, off * ss
    # Thicken the glyph a little at 1x so the snail stays visible in the menu bar.
    glyph = thickened('menu_bar_icon.svg', B, (5 if px == 18 else 2), invert=True, gap=(8 if px == 18 else 4))
    mask = squircle_mask(B, n=4.2)
    alpha = ImageChops.subtract(mask, glyph)                    # badge minus glyph
    canvas = Image.new('RGBA', (S, S), (255, 255, 255, 0))
    white = Image.new('RGBA', (B, B), (255, 255, 255, 255))
    white.putalpha(alpha)
    canvas.paste(white, (O, O), white)
    return canvas.resize((px, px), Image.BOX)

sizes = [(16, 'icon_16x16'), (32, 'icon_16x16@2x'), (32, 'icon_32x32'), (64, 'icon_32x32@2x'),
         (128, 'icon_128x128'), (256, 'icon_128x128@2x'), (256, 'icon_256x256'), (512, 'icon_256x256@2x'),
         (512, 'icon_512x512'), (1024, 'icon_512x512@2x')]
cache = {}
for px, name in sizes:
    if px not in cache: cache[px] = app_icon(px)
    cache[px].save(os.path.join(RES, 'AppIcon.iconset', name + '.png'))
menubar(18).save(os.path.join(RES, 'MenuBarIcon.png'))
menubar(36).save(os.path.join(RES, 'MenuBarIcon@2x.png'))
badge(64).save(os.path.join(RES, 'BrandBadge.png'))
badge(128).save(os.path.join(RES, 'BrandBadge@2x.png'))
badge(256).save(os.path.join(HERE, 'BrandBadge-256.png'))
print('done')
